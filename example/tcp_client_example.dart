import 'package:tcp_client/tcp_client.dart';

void main() async {
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

  // see, it's only the headers
  print(res?.body);

  // this will flush the remaining data (if there is any) to the dataStream and stringStream
  client.flush();

  // do it again on the same connection
  print('-------- DO IT AGAIN --------------');
  res = await client.sendAndWait('''GET / HTTP/1.1\r
Host: google.com\r
User-Agent: curl/7.64.1\r
Keep-Alive: false\r
Accept: */*''');

  // finally, close the connection... if `flush` were not called, this would automatically close it.
  client.close();
}
