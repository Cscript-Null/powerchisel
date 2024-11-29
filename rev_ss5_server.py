# server.py
import asyncio
import struct
import uuid
import logging
import socket

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

SOCKS_VERSION = 5

class Socks5Server:
    def __init__(self, socks_port=1080, client_port=8080):
        self.socks_port = socks_port
        self.client_port = client_port
        self.client_connection = None  # 与 client.ps1 的连接
        self.connections = {}  # connection_id: (socks_reader, socks_writer)

    async def handle_client_connection(self):
        server = await asyncio.start_server(self.handle_client, '0.0.0.0', self.client_port)
        addr = server.sockets[0].getsockname()
        logging.info(f"等待 client.ps1 连接，监听端口 {addr[1]}")
        async with server:
            await server.serve_forever()

    async def handle_client(self, reader, writer):
        if self.client_connection is not None:
            logging.warning("已有一个 client.ps1 连接，拒绝新的连接")
            writer.close()
            await writer.wait_closed()
            return

        self.client_connection = (reader, writer)
        addr = writer.get_extra_info('peername')
        logging.info(f"client.ps1 已连接来自 {addr}")

        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                message = line.decode().strip()
                logging.debug(f"收到来自 client.ps1 的消息: {message}")

                parts = message.split(' ')
                if parts[0] == 'CONNECTED' and len(parts) == 2:
                    connection_id = parts[1]
                    if connection_id in self.connections:
                        socks_reader, socks_writer = self.connections[connection_id]
                        # 开始转发数据
                        asyncio.create_task(self.forward_socks_to_client(connection_id, socks_reader))
                    else:
                        logging.warning(f"未知的连接ID: {connection_id}")
                elif parts[0] == 'FAILED' and len(parts) == 2:
                    connection_id = parts[1]
                    if connection_id in self.connections:
                        socks_reader, socks_writer = self.connections.pop(connection_id)
                        socks_writer.close()
                        await socks_writer.wait_closed()
                        logging.info(f"连接 {connection_id} 失败，关闭 SOCKS 客户端连接")
                    else:
                        logging.warning(f"未知的连接ID: {connection_id}")
                elif parts[0] == 'DATA' and len(parts) == 3:
                    connection_id = parts[1]
                    data_length = int(parts[2])
                    data = await reader.readexactly(data_length)
                    if connection_id in self.connections:
                        socks_reader, socks_writer = self.connections[connection_id]
                        socks_writer.write(data)
                        logging.debug(f"转发数据给 client.ps1，连接ID: {connection_id}, 数据长度: {data_length}")

                        await socks_writer.drain()
                        logging.debug(f"转发数据给 SOCKS 客户端，连接ID: {connection_id}, 数据长度: {data_length}")
                    else:
                        logging.warning(f"未知的连接ID: {connection_id}")
                elif parts[0] == 'CLOSE' and len(parts) == 2:
                    connection_id = parts[1]
                    if connection_id in self.connections:
                        socks_reader, socks_writer = self.connections.pop(connection_id)
                        socks_writer.close()
                        await socks_writer.wait_closed()
                        logging.info(f"连接 {connection_id} 被关闭")
                    else:
                        logging.warning(f"未知的连接ID: {connection_id}")
                else:
                    logging.warning(f"未知的命令: {message}")

        except Exception as e:
            logging.error(f"处理 client.ps1 连接时出错: {e}")
        finally:
            logging.info("client.ps1 连接已断开")
            self.client_connection = None

    async def forward_socks_to_client(self, connection_id, socks_reader):
        client_reader, client_writer = self.client_connection
        try:
            while True:
                data = await socks_reader.read(4096)
                if not data:
                    break
                # 发送数据到 client.ps1
                header = f"DATA {connection_id} {len(data)}\n".encode()
                client_writer.write(header + data)
                await client_writer.drain()
                logging.debug(f"转发数据给 client.ps1，连接ID: {connection_id}, 数据长度: {len(data)}")
        except Exception as e:
            logging.error(f"转发数据到 client.ps1 时出错: {e}")
        finally:
            # 通知 client.ps1 关闭连接
            close_command = f"CLOSE {connection_id}\n".encode()
            client_writer.write(close_command)
            await client_writer.drain()
            logging.info(f"通知 client.ps1 关闭连接，连接ID: {connection_id}")
            if connection_id in self.connections:
                self.connections.pop(connection_id)

    async def handle_socks_client(self, reader, writer):
        addr = writer.get_extra_info('peername')
        logging.info(f"收到 SOCKS5 客户端连接来自 {addr}")

        try:
            # 1. SOCKS5 握手
            data = await reader.read(2)
            if len(data) < 2:
                logging.warning("无效的 SOCKS5 握手数据")
                writer.close()
                return

            version, n_methods = data
            if version != SOCKS_VERSION:
                logging.warning(f"不支持的 SOCKS 版本: {version}")
                writer.close()
                return

            methods = await reader.read(n_methods)
            # 选择“无认证”方法
            writer.write(struct.pack("BB", SOCKS_VERSION, 0))
            await writer.drain()

            # 2. 处理 SOCKS5 请求
            data = await reader.read(4)
            if len(data) < 4:
                logging.warning("无效的 SOCKS5 请求头")
                writer.close()
                return

            ver, cmd, _, addr_type = data

            if ver != SOCKS_VERSION:
                logging.warning(f"不支持的 SOCKS 版本: {ver}")
                writer.close()
                return

            if cmd != 1:  # 仅支持 CONNECT
                logging.warning(f"不支持的 SOCKS5 命令: {cmd}")
                await self.send_socks_reply(writer, 7)  # 命令不支持
                writer.close()
                return

            # 解析目标地址
            if addr_type == 1:  # IPv4
                addr_ip_bytes = await reader.read(4)
                address = socket.inet_ntoa(addr_ip_bytes)
            elif addr_type == 3:  # 域名
                domain_length = await reader.read(1)
                if not domain_length:
                    logging.warning("无效的域名长度")
                    writer.close()
                    return
                domain_length = domain_length[0]
                domain = await reader.read(domain_length)
                address = domain.decode()
            elif addr_type == 4:  # IPv6
                addr_ip_bytes = await reader.read(16)
                address = socket.inet_ntop(socket.AF_INET6, addr_ip_bytes)
            else:
                logging.warning(f"未知的地址类型: {addr_type}")
                writer.close()
                return

            # 读取目标端口
            port_bytes = await reader.read(2)
            if len(port_bytes) < 2:
                logging.warning("无效的端口数据")
                writer.close()
                return
            port = struct.unpack('!H', port_bytes)[0]

            logging.info(f"SOCKS5 请求连接: {address}:{port}")

            # 分配唯一的连接ID
            connection_id = str(uuid.uuid4())
            self.connections[connection_id] = (reader, writer)

            # 回复 SOCKS5 客户端连接已成功
            await self.send_socks_reply(writer, 0)

            # 向 client.ps1 发送 CONNECT 命令
            if self.client_connection:
                client_reader, client_writer = self.client_connection
                connect_command = f"CONNECT {connection_id} {address} {port}\n"
                client_writer.write(connect_command.encode())
                await client_writer.drain()
                logging.info(f"发送 CONNECT 命令到 client.ps1: {connect_command.strip()}")
            else:
                logging.warning("没有可用的 client.ps1 连接")
                await self.send_socks_reply(writer, 1)  # 连接失败
                writer.close()
                return

        except Exception as e:
            logging.error(f"处理 SOCKS5 客户端时出错: {e}")
            writer.close()

    async def send_socks_reply(self, writer, reply_code, bnd_addr='0.0.0.0', bnd_port=0):
        # 构造 SOCKS5 回复
        addr = bnd_addr
        ip = socket.inet_aton(addr)
        reply = struct.pack("!BBBB", SOCKS_VERSION, reply_code, 0, 1) + ip + struct.pack("!H", bnd_port)
        writer.write(reply)
        await writer.drain()

    async def handle_socks_clients(self):
        server = await asyncio.start_server(self.handle_socks_client, '0.0.0.0', self.socks_port)
        addr = server.sockets[0].getsockname()
        logging.info(f"SOCKS5 代理服务器已启动，监听端口 {addr[1]}")
        async with server:
            await server.serve_forever()

    async def main(self):
        await asyncio.gather(
            self.handle_client_connection(),
            self.handle_socks_clients()
        )

if __name__ == "__main__":
    server = Socks5Server(socks_port=1080, client_port=8080)
    try:
        asyncio.run(server.main())
    except KeyboardInterrupt:
        logging.info("服务器已停止")
