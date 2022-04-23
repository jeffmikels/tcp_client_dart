import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'dart:typed_data';

/// two connection types: [persistent] and [untilClosed]
/// persistent means the client should handle reconnections
enum TcpConnectionType { persistent, untilClosed }

enum TcpConnectionState { disconnected, connecting, connected, failed }

/// a simple wrapper for TCP responses to allow retrieving
/// response data as [Uint8List] through [bytes] or as a [String] through [body].
class TcpMessage {
  final Uint8List bytes;
  String get body => utf8.decode(bytes, allowMalformed: true);
  const TcpMessage(this.bytes);
}

class TcpNotReady implements Exception {
  final String message;
  TcpNotReady(this.message);
  @override
  toString() => 'TcpNotReady: $message';
}

/// a simple client for arbitrary tcp connections.
///
/// This class will manage connecting and reconnecting to a server
/// and will also manage sending and receiving data to that server
class TcpClient {
  static bool debug = false;

  // remember these locally to handle reconnecting
  final String host;
  final int port;
  Duration timeout;

  /// for persistent connections, these bytes serve as the "terminator" of a tcp response
  /// if terminator is null, all the data will be streamed as it is received.
  Uint8List? terminatorBytes;

  // internal only variables
  Socket? _socket;
  Completer<Uint8List?>? _completer;
  List<int> _accumulator = [];
  bool _stopTrying = false;

  TcpConnectionType connectionType = TcpConnectionType.untilClosed;
  bool get isPersistent => connectionType == TcpConnectionType.persistent;
  bool get shouldReconnect => isPersistent && !_stopTrying;

  /// a stream to give visibility to the status of this connection which is helpful
  /// whenever the stream is in a connecting or reconnecting state
  Stream<TcpConnectionState> get connectionStream => _connectionController.stream;
  final StreamController<TcpConnectionState> _connectionController = StreamController();

  bool get isConnected => status == TcpConnectionState.connected;
  TcpConnectionState _status = TcpConnectionState.disconnected;
  TcpConnectionState get status => _status;
  set status(TcpConnectionState s) {
    if (s == _status) return;
    _status = s;
    _connectionController.add(s);
  }

  /// the stream that passes data back to listeners
  ///
  /// NOTE: [stringStream] adds a listener to [dataStream], so you should only listen to one
  /// of them, either [stringStream] or [dataStream].
  Stream<Uint8List> get dataStream => _dataController.stream;
  final StreamController<Uint8List> _dataController = StreamController();

  /// transform the data stream into a stream of strings... invalid characters
  /// will be decoded to the unicode replacement character U+FFFD (�)
  ///
  /// NOTE: This adds a listener onto the [dataStream], so you should only listen to one
  /// of them, either [stringStream] or [dataStream].
  Stream<String> get stringStream => dataStream.map((e) => utf8.decode(e, allowMalformed: true));

  /// [terminatorBytes] determines when a new item will be added to the data stream, for most
  /// TCP connections, the terminator is `\r\n` but some protocols might determine their own
  /// if this is set to null, data will be piped directly from the socket to the datastream as
  /// it comes in.
  TcpClient(
    this.host,
    this.port, {
    this.terminatorBytes,
    this.timeout = const Duration(seconds: 2),
  });

  /// Same as the default constructor, but builds the [terminatorBytes] from the UTF8 encoding
  /// of the given string.
  TcpClient.withStringTerminator(
    this.host,
    this.port,
    String terminatorString, {
    this.timeout = const Duration(seconds: 2),
  }) {
    terminatorBytes = Uint8List.fromList(terminatorString.codeUnits);
  }

  /// creates a TcpClient and immediately attempts to connect.
  /// If successful or if the requested connection should manage reconnecting
  /// on it's own, the client will complete the future. Otherwise, an exception
  /// will be thrown.
  static Future<TcpClient> connect(
    String host,
    int port, {
    String? terminatorString,
    List<int>? terminatorBytes,
    TcpConnectionType connectionType = TcpConnectionType.untilClosed,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    Uint8List? tb;
    if (terminatorString != null) terminatorBytes ??= Uint8List.fromList(utf8.encode(terminatorString));
    if (terminatorBytes != null) tb = Uint8List.fromList(terminatorBytes);
    var c = TcpClient(host, port, timeout: timeout, terminatorBytes: tb);
    if (connectionType == TcpConnectionType.persistent) {
      await c._connectPersistent();
    } else if (!await c._connect()) {
      throw TcpNotReady('Failed connecting to $host:$port');
    }
    return c;
  }

  /// creates an auto-reconnecting TcpClient and immediately attempts to connect.
  /// after the connection has been initiated, the future will be completed.
  static Future<TcpClient> connectPersistent(
    String host,
    int port, {
    String? terminatorString,
    List<int>? terminatorBytes,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    return connect(host, port,
        terminatorString: terminatorString,
        terminatorBytes: terminatorBytes,
        timeout: timeout,
        connectionType: TcpConnectionType.persistent);
  }

  /// establishes a TCP connection that stays alive until one side closes
  Future<bool> _connect() async {
    dbg('CONNECTING');
    connectionType = TcpConnectionType.untilClosed;

    /// close previous socket if open
    _socket?.close();

    status = TcpConnectionState.connecting;
    _socket = await Socket.connect(host, port, timeout: timeout);
    if (_socket == null) {
      dbg('FAILED TO CREATE SOCKET');
      status = TcpConnectionState.failed;
      return false;
    }

    dbg('SOCKET CREATED');
    status = TcpConnectionState.connected;
    _socket!.listen(_onData);
    _socket!.done.then(
      (_) {
        flush();
        dbg('SOCKET DISCONNECTED');
        status = TcpConnectionState.disconnected;
        _socket?.close();
        _socket = null;
      },
    );

    // if (terminatorBytes == null || terminatorBytes!.isEmpty) {
    //   _socket!.pipe(_dataController);
    // } else {
    //   _socket!.listen(
    //     _onData,
    //     onDone: () {
    //       status = TcpConnectionState.disconnected;
    //       _socket?.close();
    //       _socket = null;
    //     },
    //   );
    // }
    return true;
  }

  /// establishes a connection to the server and will automatically reconnect
  /// if the connection is closed or dropped.
  Future<bool> _connectPersistent([int retrySeconds = 2, int attempt = 1]) async {
    dbg('CONNECTING');
    connectionType = TcpConnectionType.persistent;
    if (attempt == 1) _stopTrying = false;
    if (attempt == 5) {
      status = TcpConnectionState.failed;
      return false;
    }
    if (_stopTrying) {
      status = TcpConnectionState.disconnected;
      return false;
    }

    attempt++;
    retrySeconds = retrySeconds > 30 ? 30 : retrySeconds;
    status = TcpConnectionState.connecting;
    try {
      _socket?.close();
      _socket = await Socket.connect(host, port);
      if (_socket == null) return _connectPersistent(retrySeconds, attempt);

      status = TcpConnectionState.connected;
      retrySeconds = 2;
      if (terminatorBytes == null || terminatorBytes!.isEmpty) {
        _socket!.pipe(_dataController);
      } else {
        _socket!.listen(_onData);
        _socket!.done.then(
          (_) {
            flush();
            dbg('SOCKET DISCONNECTED, ATTEMPTING RECONNECT');
            status = TcpConnectionState.disconnected;
            _socket?.close();
            _socket = null;
            Timer(
              Duration(seconds: retrySeconds),
              () => _connectPersistent(retrySeconds + 2, attempt = 1),
            );
          },
        );
      }
    } catch (e) {
      print(e);
      status = TcpConnectionState.failed;
      return false;
    }
    return true;
  }

  void stopTrying() => _stopTrying = true;
  void dbg(Object msg) {
    if (debug) print(msg);
  }

  /// will wait until all socket data has been flushed to the socket
  /// and then will close it.
  Future close() async {
    stopTrying();
    await _socket?.flush();
    await _socket?.close();
  }

  /// will pass the given bytes directly to the [Socket.add] method
  /// Note: you should probably use [send] instead.
  void add(Uint8List bytes) => _socket?.add(bytes);

  /// will pass the given object directly to the [Socket.write] method
  /// (using [Object.toString] if needed)
  /// Note: you should probably use [send] instead.
  void write(Object msg) => _socket?.write(msg);

  /// will send a message to the socket. If the message is a list of bytes,
  /// (i.e. `Uint8List` or `List<int>`) the bytes will be sent directly.
  ///
  /// Otherwise, the message will be converted to a string with [Object.toString],
  /// encoded to UTF-8, and then sent to the socket.
  ///
  /// The [terminatorBytes], if set, will be automatically appended to the
  /// end of the message, unless [appendTerminator] is set to `false`.
  void send(Object msg, {appendTerminator = true}) {
    if (_socket == null) {
      throw TcpNotReady('socket not created... did you forget to call `connect` or `connectPersistent`?');
    }
    late Uint8List bytes;
    if (msg is Uint8List) {
      bytes = msg;
    } else if (msg is List<int>) {
      bytes = Uint8List.fromList(msg);
    } else {
      bytes = Uint8List.fromList(utf8.encode(msg.toString()));
    }

    if (terminatorBytes != null && appendTerminator) {
      bytes = Uint8List.fromList([...bytes, ...terminatorBytes!]);
    }
    dbg(bytes);
    add(bytes);
  }

  /// will send a single message to the socket and then immediately close it.
  /// Use this when you don't care about the response.
  Future sendAndClose(Object msg, {appendTerminator = true}) {
    send(msg, appendTerminator: appendTerminator);
    return close();
  }

  /// will send a message to the socket, and will reply with a future
  /// that resolves to the next message received on the socket.
  ///
  /// NOTE: This function will automatically append the terminator bytes
  /// if they have been specified.
  Future<TcpMessage?> sendAndWait(Object msg, {appendTerminator = true}) async {
    // wait for the previous completer to complete or fail
    await _completer?.future;
    _completer = Completer<Uint8List?>();
    send(msg, appendTerminator: appendTerminator);
    var res = await _completer!.future.timeout(timeout, onTimeout: () {
      return null;
    });
    if (res == null) return null;
    return TcpMessage(res);
  }

  void _onData(Uint8List data) {
    dbg('DATA RECEIVED');
    dbg(data);
    if (terminatorBytes != null) {
      // we could have done this by converting everything to and from UTF strings and
      // then used String.split, but doing everything with bytes just felt faster to me
      _accumulator.addAll(data);
      var messages = _byteSplit((Uint8List.fromList(_accumulator)), terminatorBytes!);

      // if the accumulator ends with a terminator, the last element will be empty
      // otherwise the final bit of data has not been terminated yet and should be
      // retained for the next time
      _accumulator = messages.removeLast().toList();
      for (var message in messages) {
        _dataController.add(message);

        // complete the completer with the first message
        if (_completer != null && !_completer!.isCompleted) {
          _completer!.complete(message);
        }
      }
    } else {
      _dataController.add(data);
      _completer?.complete(data);
    }
  }

  /// works like string split. If delimiter is an empty list,
  /// each byte will be returned separately.
  List<Uint8List> _byteSplit(Uint8List source, List<int> delimiter) {
    List<Uint8List> retval = [];
    int width = delimiter.length;
    var start = 0;
    var cursor = 0;
    while (cursor < source.length) {
      // assume we are at the start of a delimiter
      var isDelim = true;
      for (var i = 0; i < width; i++) {
        if (cursor + i >= source.length || source[cursor + i] != delimiter[i]) {
          isDelim = false;
          break;
        }
      }
      if (isDelim) {
        if (width == 0) cursor++;
        var sub = Uint8List.sublistView(source, start, cursor);
        dbg(sub);
        retval.add(sub);
        cursor += width;
        start = cursor;
      } else {
        cursor++;
      }
    }

    /// if width is 0, the last element was already included
    if (width > 0) retval.add(Uint8List.sublistView(source, start, cursor));
    return retval;
  }

  void flush() {
    if (_accumulator.isNotEmpty) {
      _dataController.add(Uint8List.fromList(_accumulator));
      _accumulator.clear();
    }
  }
}
