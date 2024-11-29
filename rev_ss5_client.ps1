param(
    [string]$server = "192.168.239.199", # Replace with the server's IP address
    [int]$port = 8080
)

$bufferSize = 8192 
$connections = @{} 
$client = New-Object System.Net.Sockets.TcpClient
$client.ConnectAsync($server, $port).Wait() | Out-Null
$client.Wait() 

$stream = $client.GetStream()

# Function to read lines asynchronously from the network stream
function ReadLineAsync {
    param (
        [System.IO.Stream]$stream
    )
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $buffer = New-Object System.Byte[] 1
        $bytesRead = $stream.ReadAsync($buffer, 0, 1).Result
        if ($bytesRead -eq 0) {
            return $null  # Stream closed
        }
        $char = [System.Text.Encoding]::ASCII.GetString($buffer)
        if ($char -eq "`n") {
            break
        }
        else {
            $sb.Append($char) | Out-Null
        }
    }
    return $sb.ToString()
}

# Function to handle data forwarding between server.py and the target server
function HandleConnection {
    param (
        [string]$connection_id,
        [System.Net.Sockets.TcpClient]$targetClient
    )

    $targetStream = $targetClient.GetStream()
    $connection = @{
        ConnectionId = $connection_id
        TargetClient = $targetClient
        TargetStream = $targetStream
    }
    $connections[$connection_id] = $connection

    # Start reading data from target server asynchronously
    $receiveBuffer = New-Object Byte[] $bufferSize
    $receiveTask = $targetStream.ReadAsync($receiveBuffer, 0, $receiveBuffer.Length)

    # Begin processing data from server.py
    while ($true) {
        # Check if target server sent data
        if ($receiveTask.IsCompleted) {
            $bytesReceived = $receiveTask.Result
            if ($bytesReceived -gt 0) {
                # Send data back to server.py
                $dataHeader = "DATA $connection_id $bytesReceived`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($dataHeader)
                $stream.WriteAsync($headerBytes, 0, $headerBytes.Length) | Out-Null
                $stream.WriteAsync($receiveBuffer, 0, $bytesReceived) | Out-Null
                $stream.FlushAsync() | Out-Null

                # Start another read
                $receiveTask = $targetStream.ReadAsync($receiveBuffer, 0, $receiveBuffer.Length)
            }
            else {
                # Connection closed by target server
                # Notify server.py
                $closeCommand = "CLOSE $connection_id`n"
                $closeBytes = [System.Text.Encoding]::ASCII.GetBytes($closeCommand)
                $stream.WriteAsync($closeBytes, 0, $closeBytes.Length) | Out-Null
                $stream.FlushAsync() | Out-Null

                # Clean up
                $targetStream.Dispose()
                $targetClient.Dispose()
                $connections.Remove($connection_id)
                break
            }
        }

        # Check if data is available from server.py
        if ($stream.DataAvailable) {
            $line = ReadLineAsync -stream $stream
            if ($null -eq $line) {
                break  # Server closed the connection
            }
            $messageParts = $line.Split(' ')
            $command = $messageParts[0]
            if ($command -eq 'DATA' -and $messageParts.Length -eq 3) {
                $connId = $messageParts[1]
                $length = [int]$messageParts[2]

                # Read the specified amount of data
                $dataBuffer = New-Object Byte[] $length
                $totalRead = 0
                while ($totalRead -lt $length) {
                    $read = $stream.ReadAsync($dataBuffer, $totalRead, $length - $totalRead).Result
                    if ($read -le 0) {
                        break
                    }
                    $totalRead += $read
                }

                # Send data to target server
                $targetStream.WriteAsync($dataBuffer, 0, $dataBuffer.Length) | Out-Null
                $targetStream.FlushAsync() | Out-Null
            }
            elseif ($command -eq 'CLOSE' -and $messageParts.Length -eq 2) {
                $connId = $messageParts[1]
                if ($connections.ContainsKey($connId)) {
                    # Close connection to target server
                    $conn = $connections[$connId]
                    $conn.TargetStream.Dispose()
                    $conn.TargetClient.Dispose()
                    $connections.Remove($connId)
                }
            }
        }

        # Small sleep to prevent tight loop
        Start-Sleep -Milliseconds 10
    }
}

# Main loop to read commands from server.py
try {
    while ($true) {
        $line = ReadLineAsync -stream $stream
        if ($null -eq $line) {
            break  # Connection closed
        }
        $messageParts = $line.Split(' ')
        $command = $messageParts[0]

        if ($command -eq 'CONNECT' -and $messageParts.Length -eq 4) {
            $connection_id = $messageParts[1]
            $address = $messageParts[2]
            $port = [int]$messageParts[3]

            # Asynchronously connect to target server
            $targetClient = New-Object System.Net.Sockets.TcpClient
            $connectTask = $targetClient.ConnectAsync($address, $port)

            if ($connectTask.Wait(5000)) {
                # Connection successful
                $connectedCommand = "CONNECTED $connection_id`n"
                $connectedBytes = [System.Text.Encoding]::ASCII.GetBytes($connectedCommand)
                $stream.WriteAsync($connectedBytes, 0, $connectedBytes.Length) | Out-Null
                $stream.FlushAsync() | Out-Null

                # Start handling the connection
                HandleConnection -connection_id $connection_id -targetClient $targetClient
            }
            else {
                # Connection failed
                $failedCommand = "FAILED $connection_id`n"
                $failedBytes = [System.Text.Encoding]::ASCII.GetBytes($failedCommand)
                $stream.WriteAsync($failedBytes, 0, $failedBytes.Length) | Out-Null
                $stream.FlushAsync() | Out-Null
                $targetClient.Dispose()
            }
        }
        else {
            # Unknown command or data forwarding commands handled in HandleConnection
        }

        # Small sleep to prevent tight loop
        Start-Sleep -Milliseconds 10
    }
}
catch {
    Write-Error "An error occurred: $_"
}
finally {
    # Clean up
    foreach ($conn in $connections.Values) {
        $conn.TargetStream.Dispose()
        $conn.TargetClient.Dispose()
    }
    $stream.Dispose()
    $client.Dispose()
}