# SOCKS5 Proxy Server in PowerShell
# ==================================


$Config = @{
    ListenIP = "0.0.0.0"       
    ListenPort = 1080          
    MaxConnections = 100       
    Timeout = 300              
    LogPath = "C:\socks5_server.log" 
}


function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"
    Add-Content -Path $Config.LogPath -Value $logMessage
    Write-Host $logMessage
}


function Start-Listener {
    param (
        [string]$IP,
        [int]$Port
    )
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($IP), $Port)
        $listener.Start()
        Write-Log "Listening on $IP : $Port"
        return $listener
    }
    catch {
        Write-Log "Failed to start listener on $IP : $Port - $_" "ERROR"
        exit
    }
}


function Handle-Socks5Client {
    param (
        [System.Net.Sockets.TcpClient]$client
    )

    try {
        $clientStream = $client.GetStream()
        $buffer = New-Object byte[] 1024
        $read = $clientStream.Read($buffer, 0, $buffer.Length)

        if ($read -le 0) {
            Write-Log "Empty handshake received. Closing connection." "WARN"
            $client.Close()
            return
        }

        # 解析握手
        $version = $buffer[0]
        $nmethods = $buffer[1]
        $methods = $buffer[2..($nmethods+1)]

        if ($version -ne 5) {
            Write-Log "Unsupported SOCKS version: $version. Closing connection." "WARN"
            $client.Close()
            return
        }

        
        $response = [byte[]](5, 0)
        $clientStream.Write($response, 0, $response.Length)

        
        $read = $clientStream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            Write-Log "Empty request received. Closing connection." "WARN"
            $client.Close()
            return
        }

        $version = $buffer[0]
        $cmd = $buffer[1]
        $reserved = $buffer[2]
        $addressType = $buffer[3]

        if ($version -ne 5) {
            Write-Log "Unsupported SOCKS version in request: $version. Closing connection." "WARN"
            $client.Close()
            return
        }

        
        if ($cmd -ne 1) {
            Write-Log "Unsupported CMD: $cmd. Closing connection." "WARN"
            $reply = [byte[]](5, 7, 0, 1) + [byte[]](0,0,0,0) + [byte[]](0,0)
            $clientStream.Write($reply, 0, $reply.Length)
            $client.Close()
            return
        }

        switch ($addressType) {
            1 { 
                $dstAddr = "{0}.{1}.{2}.{3}" -f $buffer[4],$buffer[5],$buffer[6],$buffer[7]
                $addressEnd = 8
            }
            3 { 
                $addrLen = $buffer[4]
                $dstAddr = [System.Text.Encoding]::ASCII.GetString($buffer, 5, $addrLen)
                $addressEnd = 5 + $addrLen
            }
            4 { 
                $dstAddr = [System.Net.IPAddress]::new($buffer, 4).ToString()
                $addressEnd = 20
            }
            default {
                Write-Log "Unsupported address type: $addressType. Closing connection." "WARN"
                $reply = [byte[]](5, 8, 0, 1) + [byte[]](0)*16 + [byte[]](0,0)
                $clientStream.Write($reply, 0, $reply.Length)
                $client.Close()
                return
            }
        }


        $dstPort = ($buffer[$addressEnd] * 256) + $buffer[$addressEnd + 1]

        Write-Log "Request to connect to $dstAddr : $dstPort"


        try {
            $remote = [System.Net.Sockets.TcpClient]::new()
            $remote.Connect($dstAddr, $dstPort)
            $reply = [byte[]](5, 0, 0, $addressType)

            switch ($addressType) {
                1 { # IPv4
                    $ipBytes = [System.Net.IPAddress]::Parse($dstAddr).GetAddressBytes()
                    $reply += $ipBytes
                }
                3 { 
                    $addrBytes = [System.Text.Encoding]::ASCII.GetBytes($dstAddr)
                    $reply += [byte]($addrBytes.Length)
                    $reply += $addrBytes
                }
                4 { # IPv6
                    $ipBytes = [System.Net.IPAddress]::Parse($dstAddr).GetAddressBytes()
                    $reply += $ipBytes
                }
            }

            $reply += [byte]($dstPort / 256)
            $reply += [byte]($dstPort % 256)

            $clientStream.Write($reply, 0, $reply.Length)
        }
        catch {
            Write-Log "Failed to connect to $dstAddr : $dstPort - $_" "ERROR"
            $reply = [byte[]](5, 5, 0, 1) + [byte[]](0)*6
            $clientStream.Write($reply, 0, $reply.Length)
            $client.Close()
            return
        }

        $remoteStream = $remote.GetStream()

        $forwardJob = [PowerShell]::Create().AddScript({
            param($fromStream, $toStream)
            try {
                while (($bytesRead = $fromStream.Read($buffer = New-Object byte[] 4096, 0, 4096)) -gt 0) {
                    $toStream.Write($buffer, 0, $bytesRead)
                    $toStream.Flush()
                }
            }
            catch {}
            finally {
                $toStream.Close()
            }
        }).AddArgument($clientStream).AddArgument($remoteStream).BeginInvoke()

        $reverseJob = [PowerShell]::Create().AddScript({
            param($fromStream, $toStream)
            try {
                while (($bytesRead = $fromStream.Read($buffer = New-Object byte[] 4096, 0, 4096)) -gt 0) {
                    $toStream.Write($buffer, 0, $bytesRead)
                    $toStream.Flush()
                }
            }
            catch {}
            finally {
                $toStream.Close()
            }
        }).AddArgument($remoteStream).AddArgument($clientStream).BeginInvoke()

        [System.Threading.Tasks.Task]::WaitAll(@($forwardJob.AsyncWaitHandle, $reverseJob.AsyncWaitHandle), $Config.Timeout * 1000)
    }
    catch {
        Write-Log "Error handling client: $_" "ERROR"
    }
    finally {
        if ($client.Connected) {
            $client.Close()
        }
    }
}


function Start-ProxyServer {
    $listener = Start-Listener -IP $Config.ListenIP -Port $Config.ListenPort
    $connections = 0

    while ($true) {
        try {
            if ($listener.Pending() -and $connections -lt $Config.MaxConnections) {
                $client = $listener.AcceptTcpClient()
                $connections++

                Write-Log "Accepted connection from $($client.Client.RemoteEndPoint). Total connections: $connections"

                
                Start-Job -ScriptBlock {
                    param($client)
                    Handle-Socks5Client -client $client
                } -ArgumentList $client | Out-Null
            }
            else {
                Start-Sleep -Milliseconds 100
            }

            
            Get-Job | Where-Object { $_.State -eq 'Completed' } | ForEach-Object {
                Remove-Job $_
                $connections--
                Write-Log "Connection closed. Total connections: $connections"
            }

        }
        catch {
            Write-Log "Error in main loop: $_" "ERROR"
        }
    }
}

Start-ProxyServer
