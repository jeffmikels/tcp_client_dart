## Features

This library provides a single class `TcpClient` that manages connecting, disconnecting, and automatically reconnecting to another machine `TCP`. Received data is exposed as a `Stream` that remains consistent even if the underlying socket disconnects and reconnects.

Additionally, the connection status of the socket is also exposed as a `Stream`.

This class makes it easy to send and receive data as bytes or strings, and it optionally can wrap the send functions in a `Future` that will resolve with the server's response.

Additionally, this class allows you to specify a `terminator` as either bytes or strings to identify
when a full 'message' has been received or not. For example, standard Telnet clients use `\r\n` as the string that separates messages from each other, and `HTTP` uses `\r\n\r\n` to separate different parts of a message. Each `TCP` protocol should define its own terminator.

This class makes no assumption about the encoding of transferred data and does all its communication as `Uint8List` objects (bytes). Therefore, the terminator can also be specified in bytes. Many network protocols that transmit binary data use specific byte combinations for their terminator strings.

Finally, the terminator may be `null`. In the case of a `null` terminator, all data received over the socket will be piped directly to the data stream.

## Getting started

```bash
dart pub add tcp_client
```

If using Flutter:

```bash
flutter pub add tcp_client
```

## Usage

```dart
import 'package:tcp_client/tcp_client.dart';

// turn on debug mode
TcpClient.debug = false;
var client = await TcpClient.connect('google.com', 80, terminatorString: '\r\n\r\n');

// this will watch the connection status
client.connectionStream.listen(print);

// this will print out all the received data directly
// client.dataStream.listen(print);

// this will transform all received data into strings
client.stringStream.listen(print);

// res will complete with only the first message as delimited by the terminator
// in this case (an HTTP request) that will be the headers only
var res = await client.sendAndWait('''GET / HTTP/1.1\r
Host: google.com\r
User-Agent: curl/7.64.1\r
Keep-Alive: false\r
Accept: */*''');

// res now has the headers
print(res?.body);

// to get the rest of the data (since HTTP doesn't terminate at the end)
client.flush();

// clean up
client.close();

```

## Additional information

Suggestions and contributions are welcome.
