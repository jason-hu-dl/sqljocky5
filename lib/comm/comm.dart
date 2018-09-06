import 'dart:async';
import 'dart:io';

import '../handlers/handler.dart';
import 'task_queue.dart';
import 'package:typed_buffer/typed_buffer.dart';
import 'buffered_socket.dart';
import '../auth/ssl_handler.dart';
import 'package:sqljocky5/exceptions/exceptions.dart';
import '../results/results.dart';
import '../auth/handshake_handler.dart';
import '../connection/settings.dart';

import 'common.dart';
import 'receiver.dart';
import 'sender.dart';

class Comm {
  /// Underlying socket
  final BufferedSocket _socket;

  /// Implements the reception logic
  final Receiver _receiver;

  /// Implements the transmission logic
  final Sender _sender;

  final _packetNums = PacketNumber();

  final _queue = TaskQueue();

  Handler _handler;

  Completer _completer;

  bool _useCompression = false;

  bool _useSSL = false;

  Comm(this._socket, this._handler, this._completer, int maxPacketSize)
      : _receiver = Receiver(_socket),
        _sender = Sender(_socket, maxPacketSize);

  void close() => _socket.close();

  Future<void> readPacket() async {
    RxPacket packet = await _receiver.receive();
    if (packet != null) {
      _packetNums.packNum = packet.packetNum;
      _processReceived(packet.data);
    }
  }

  Future<void> _processReceived(ReadBuffer buffer) async {
    try {
      HandlerResponse response = _handler.processResponse(buffer);

      if (_handler is HandshakeHandler) {
        _useCompression = (_handler as HandshakeHandler).useCompression;
        _useSSL = (_handler as HandshakeHandler).useSSL;
      }

      if (response.nextHandler != null) {
        // if handler.processResponse() returned a Handler, pass control to that
        // handler now
        _handler = response.nextHandler;
        await _sender.send(_handler.createRequest(), _packetNums,
            compress: _useCompression);
        if (_useSSL && _handler is SSLHandler) {
          await _socket.startSSL();
          _handler = (_handler as SSLHandler).nextHandler;
          await _sender.send(_handler.createRequest(), _packetNums,
              compress: _useCompression);
          return;
        }
      }

      if (response.hasFinished) {
        _finishAndReuse();
        if (_completer.isCompleted)
          _completer.completeError(StateError("Already completed!"));
        _completer.complete(response.result);
      }
    } on MySqlException catch (e, st) {
      // This clause means mysql returned an error on the wire. It is not a fatal error
      // and the connection can stay open.
      _finishAndReuse();
      forwardError(e, st: st, keepOpen: true);
    } catch (e, st) {
      // Errors here are fatal_finishAndReuse();
      forwardError(e, st: st);
    }
  }

  void _finishAndReuse() {
    _handler = null;
    // stdout.write("Finished!");
  }

  /// Processes a handler, from sending the initial request to handling any
  /// packets returned from mysql
  Future<dynamic> _processHandler(Handler handler) async {
    if (_handler != null) {
      throw MySqlClientError(
          "Connection cannot process a request for $handler while a request is already in progress for $_handler");
    }
    var myCompleter = Completer<dynamic>();
    _completer = myCompleter;
    _handler = handler;

    _packetNums.reset();

    await _sender.send(handler.createRequest(), _packetNums,
        compress: _useCompression);
    return _completer.future;
  }

  Future<dynamic> execHandler(Handler handler, Duration timeout) =>
      _queue.run(() => _processHandler(handler).timeout(timeout));

  Future<StreamedResults> execResultHandler(
      HandlerWithResult handler, Duration timeout) async {
    var completer = Completer<StreamedResults>();
    _queue
        .run(() => _processHandler(handler).timeout(timeout))
        .catchError((e, st) {
      completer.completeError(e, st);
    });
    handler.streamedResults.then((sr) => completer.complete(sr));
    return completer.future;
  }

  /// This method just sends the handler data.
  Future<void> _execHandlerNoResponse(Handler handler) async {
    if (_handler != null) {
      throw MySqlClientError(
          "Connection cannot process a request for $handler while a request is already in progress for $_handler");
    }
    _packetNums.reset();
    await _sender.send(handler.createRequest(), _packetNums,
        compress: _useCompression);
  }

  Future<void> execHandlerNoResponse(Handler handler, Duration timeout) {
    return _queue.run(() => _execHandlerNoResponse(handler).timeout(timeout));
  }

  /// Forwards error
  void forwardError(e, {bool keepOpen = false, st}) {
    if (_completer != null) {
      if (!_completer.isCompleted) _completer.completeError(e, st);
    }
    if (!keepOpen) close();
  }

  static Future<Comm> connect(ConnectionSettings c) async {
    assert(!c.useSSL); // Not implemented
    assert(!c.useCompression);

    Comm comm;
    final handshakeCompleter = Completer();

    final socket = await BufferedSocket.connect(c.host, c.port,
        onDataReady: () => comm?.readPacket(),
        onError: (error) {
          // If conn has not been connected there was a connection error.
          if (comm == null) {
            handshakeCompleter.completeError(error);
          } else {
            comm.forwardError(error);
          }
        },
        onClosed: () {
          comm.forwardError(new SocketException.closed());
        });

    var handler = HandshakeHandler(c.user, c.password, c.maxPacketSize,
        c.characterSet, c.db, c.useCompression, c.useSSL);

    comm = Comm(socket, handler, handshakeCompleter, c.maxPacketSize);

    await handshakeCompleter.future;

    return comm;
  }

  static const int statePacketHeader = 0;
  static const int statePacketData = 1;
}
