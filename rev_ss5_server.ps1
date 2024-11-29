# server.ps1
param(
    [int]$SocksPort = 1080,
    [int]$ClientPort = 8080
)

# Import necessary .NET classes
Add-Type -AssemblyName System.Net, System.IO, System.Threading
[System.Reflection.Assembly]::LoadWithPartialName("System.Net.Sockets") | out-Null
# Store the connection to the client
$global:ClientConnection = $null

# Function: Handle connection from client.ps1
function Handle-Client-Connection {
    param($clientSocket)
    
    Write-Host "Client connected"
    $global:ClientConnection = $clientSocket
    $stream = $clientSocket.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    while ($clientSocket.Connected) {
        try {
            # Wait for data/command from the client
            $commandLine = $reader.ReadLine()
            if ($null -eq $commandLine) { break }

            $parts = $commandLine.Split(' ')
            if ($parts[0] -eq 'DATA' -and $parts.Length -ge 3) {
                $ConnectionId = $parts[1]
                $DataLength = [int]$parts[2]
                $Data = $reader.ReadLine()

                # Process data received from client.ps1 and forward it to the corresponding SOCKS5 client
                if ($global:SocksConnections.ContainsKey($ConnectionId)) {
                    $socksStream = $global:SocksConnections[$ConnectionId]
                    $socksStream.Write([System.Text.Encoding]::UTF8.GetBytes($Data), 0, [System.Text.Encoding]::UTF8.GetByteCount($Data))
                }
            }
        } catch {
            Write-Error $_.Exception.Message
            break
        }
    }

    $clientSocket.Close()
    $global:ClientConnection = $null
}

# Function: Handle SOCKS5 client connection
function Handle-SOCKS5-Client {
    param($socksClient)

    try {
        $socksStream = $socksClient.GetStream()

        # 1. SOCKS5 handshake
        $buffer = New-Object Byte[] 2
        $bytesRead = $socksStream.Read($buffer, 0, 2)
        if ($bytesRead -lt 2 -or $buffer[0] -ne 0x05) {
            Write-Host "Invalid SOCKS5 handshake request"
            $socksClient.Close()
            return
        }

        $nMethods = $buffer[1]
        $methods = New-Object Byte[] $nMethods
        $socksStream.Read($methods, 0, $nMethods) | Out-Null

        # Select "no authentication" method
        $socksStream.WriteByte(0x05)
        $socksStream.WriteByte(0x00)

        # 2. Handle SOCKS5 request
        $buffer = New-Object Byte[] 4
        $bytesRead = $socksStream.Read($buffer, 0, 4)
        if ($bytesRead -lt 4 -or $buffer[0] -ne 0x05) {
            Write-Host "Invalid SOCKS5 request"
            $socksClient.Close()
            return
        }

        $cmd = $buffer[1]
        $addrType = $buffer[3]

        if ($cmd -ne 0x01) { # Only support CONNECT command
            Write-Host "Unsupported SOCKS5 command: $cmd"
            # Reply with "command not supported"
            $reply = [Byte[]](0x05, 0x07, 0x00, 0x01) + [System.Net.IPAddress]::Any.GetAddressBytes() + [Byte[]](0x00, 0x00)
            $socksStream.Write($reply, 0, $reply.Length)
            $socksClient.Close()
            return
        }

        # Parse target address
        switch ($addrType) {
            0x01 { # IPv4
                $addrBuffer = New-Object Byte[] 4
                $socksStream.Read($addrBuffer, 0, 4) | Out-Null
                $address = [System.Net.IPAddress]::new($addrBuffer).ToString()
            }
            0x03 { # Domain name
                $len = $socksStream.ReadByte()
                if ($len -le 0) {
                    Write-Host "Invalid domain name length"
                    $socksClient.Close()
                    return
                }
                $addrBuffer = New-Object Byte[] $len
                $socksStream.Read($addrBuffer, 0, $len) | Out-Null
                $address = [System.Text.Encoding]::ASCII.GetString($addrBuffer)
            }
            0x04 { # IPv6
                $addrBuffer = New-Object Byte[] 16
                $socksStream.Read($addrBuffer, 0, 16) | Out-Null
                $address = [System.Net.IPAddress]::new($addrBuffer).ToString()
            }
            default {
                Write-Host "Unknown address type: $addrType"
                $socksClient.Close()
                return
            }
        }

        # Read target port
        $portBuffer = New-Object Byte[] 2
        $socksStream.Read($portBuffer, 0, 2) | Out-Null
        $port = [System.BitConverter]::ToUInt16(($portBuffer), 0)

        Write-Host "Received SOCKS5 request: ${address}:${port}"

        # Assign a unique connection ID
        $connectionId = [Guid]::NewGuid().ToString()

        # Store the connection
        if (-not $global:SocksConnections) {
            $global:SocksConnections = @{}
        }
        $global:SocksConnections[$connectionId] = $socksStream

        # Reply to SOCKS5 client that the connection is successful
        $reply = [Byte[]](0x05, 0x00, 0x00, 0x01) + [System.Net.IPAddress]::Any.GetAddressBytes() + [Byte[]](0x00, 0x00)
        $socksStream.Write($reply, 0, $reply.Length)

        # Send CONNECT command to client.ps1
        if ($global:ClientConnection -ne $null -and $global:ClientConnection.Connected) {
            $clientStream = $global:ClientConnection.GetStream()
            $clientWriter = New-Object System.IO.StreamWriter($clientStream)
            $clientWriter.AutoFlush = $true
            $command = "CONNECT $connectionId $address $port"
            $clientWriter.WriteLine($command)

            # Optionally, add logic to wait for confirmation from client.ps1
        } else {
            Write-Host "No available client.ps1 connection"
            # Reply to SOCKS5 client that the connection failed
            $reply = [Byte[]](0x05, 0x01, 0x00, 0x01) + [System.Net.IPAddress]::Any.GetAddressBytes() + [Byte[]](0x00, 0x00)
            $socksStream.Write($reply, 0, $reply.Length)
            $socksClient.Close()
            $global:SocksConnections.Remove($connectionId)
        }

    } catch {
        Write-Error $_.Exception.Message
        $socksClient.Close()
    }
}

# Create a TCP listener for the SOCKS5 proxy
$SocksListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $SocksPort)
$SocksListener.Start()
Write-Host "SOCKS5 proxy server started, listening on port $SocksPort"

# Create a TCP listener for client.ps1 connections
$ClientListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $ClientPort)
$ClientListener.Start()
Write-Host "Waiting for client.ps1 connection, listening on port $ClientPort"

# Start a job to handle client.ps1 connections
Start-Job -ScriptBlock {
    while ($true) {
        try {
            $clientSocket = $ClientListener.AcceptTcpClient()
            Handle-Client-Connection -clientSocket $clientSocket
        } catch {
            Write-Error $_.Exception.Message
        }
    }
}

# Main loop to accept SOCKS5 client connections
while ($true) {
    try {
        $socksClient = $SocksListener.AcceptTcpClient()
        Write-Host "SOCKS5 client connected"
        Start-Job -ScriptBlock {
            param($socksClientParam)
            Handle-SOCKS5-Client -socksClient $socksClientParam
        } -ArgumentList $socksClient
    } catch {
        Write-Error $_.Exception.Message
    }
}
