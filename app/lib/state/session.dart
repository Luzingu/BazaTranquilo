import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;

import '../core/api.dart';
import '../core/config.dart';
import '../core/servidores.dart';
import '../core/models.dart';
import '../services/notifier.dart';
import '../services/push.dart';

enum AppMode { passenger, driver }

/// Sessão do utilizador: token, perfil e socket.
class Session extends ChangeNotifier {
  final api = ApiClient();
  final _storage = const FlutterSecureStorage();

  User? user;

  /// O perfil vem da conta: motorista ou passageiro.
  AppMode get mode =>
      (user?.isDriver ?? false) ? AppMode.driver : AppMode.passenger;
  bool loading = true;
  sio.Socket? _socket;

  // ── Agente de um posto policial ───────────────────────────────────────────
  // O agente usa a mesma aplicação: o servidor reconhece o número e, depois do
  // código SMS, devolve um "bilhete"; com ele e com a senha abre-se a sessão.
  /// O agente com sessão iniciada (nome, patente, posto), ou null.
  Map<String, dynamic>? agent;

  /// Bilhete do código SMS, à espera da senha.
  String? agentTicket;

  /// Se o agente já tem senha (senão, escolhe-a agora).
  bool agentHasPassword = false;

  /// Identificador deste telemóvel: a conta do agente fica associada a ele.
  Future<String> _deviceId() async {
    var id = await _storage.read(key: 'deviceId');
    if (id == null) {
      final r = Random.secure();
      id = List.generate(
        24,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await _storage.write(key: 'deviceId', value: id);
    }
    return id;
  }

  Future<void> openAgentSession(String password) async {
    final res = await api.post('/agent/session', {
      'ticket': agentTicket,
      'password': password,
      'deviceId': await _deviceId(),
    });
    api.token = res['token'] as String;
    agent = res['agent'] as Map<String, dynamic>;
    agentTicket = null;
    await _storage.write(key: 'agentToken', value: api.token);
    _registerPush();
    notifyListeners();
  }

  void cancelAgentLogin() {
    agentTicket = null;
    notifyListeners();
  }

  void setAgent(Map<String, dynamic> value) {
    agent = value;
    notifyListeners();
  }

  Future<void> init() async {
    Notifier.instance.onForegroundChanged = _onForegroundChanged;
    try {
      final agentToken = await _storage.read(key: 'agentToken');
      if (agentToken != null) {
        api.token = agentToken;
        try {
          agent = (await api.get('/agent/me'))['agent'] as Map<String, dynamic>;
          _registerPush();
          return;
        } on ApiException catch (e) {
          if (e.status == 401) {
            api.token = null;
            await _storage.delete(key: 'agentToken');
          } else {
            initError = e.message;
            return;
          }
        }
      }
      final token = await _storage.read(key: 'token');
      if (token != null) {
        api.token = token;
        try {
          final res = await api.get('/me');
          user = User.fromJson(res['user'] as Map<String, dynamic>);
          _connect();
          _registerPush();
        } on ApiException catch (e) {
          // Só termina a sessão se o servidor a rejeitar; sem rede mantém o token.
          if (e.status == 401) {
            api.token = null;
            await _storage.delete(key: 'token');
          } else {
            initError = e.message;
          }
        }
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Erro ao restaurar a sessão (ex.: servidor inacessível).
  String? initError;

  Future<void> retry() async {
    initError = null;
    loading = true;
    notifyListeners();
    await init();
  }

  // `role` é 'passenger' ou 'driver': cada número só tem um tipo de conta, e
  // o servidor recusa-o no outro tipo (o ecrã de entrada oferece a troca).

  /// Pede o código SMS. Em desenvolvimento a API devolve o código.
  Future<String?> requestOtp(String role, String phone) async {
    final res = await api.post('/auth/otp/request', {
      'role': role,
      'phone': phone,
    });
    return res['devCode'] as String?;
  }

  Future<void> verifyOtp(String role, String phone, String code) async =>
      _signedIn(
        await api.post('/auth/otp/verify', {
          'role': role,
          'phone': phone,
          'code': code,
        }),
      );

  /// Primeiro passo da entrada: o servidor decide se pede o código SMS
  /// (`method: otp`, com `devCode` em desenvolvimento) ou a senha
  /// (`method: password`). Com [noCode], só pergunta se a conta pode usar a
  /// senha, sem reenviar o código.
  Future<Map<String, dynamic>> startLogin(
    String role,
    String phone, {
    bool noCode = false,
  }) => api.post('/auth/start', {
    'role': role,
    'phone': phone,
    if (noCode) 'noCode': true,
  });

  Future<void> loginWithPassword(
    String role,
    String phone,
    String password,
  ) async => _signedIn(
    await api.post('/auth/password/login', {
      'role': role,
      'phone': phone,
      'password': password,
    }),
  );

  /// Cria a conta quando o SMS falhou: o servidor deu um bilhete em
  /// `/auth/start` (`method: signup`). O número fica por confirmar.
  Future<void> signupWithoutCode(String ticket, String password) async =>
      _signedIn(
        await api.post('/auth/signup', {
          'ticket': ticket,
          'password': password,
        }),
      );

  /// A conta tinha o número por confirmar e acabou de ser confirmado por SMS
  /// no ecrã de entrada: por segurança, escolhe-se uma senha nova.
  bool phoneRecovered = false;

  /// Confirma o número da própria conta com o código SMS.
  Future<void> confirmOwnPhone(String code) async {
    final res = await api.post('/me/phone-confirmation/verify', {
      'code': code,
    });
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  /// Define a senha (conta nova) ou muda-a (com a [current]).
  Future<void> setPassword(String password, {String? current}) async {
    final res = await api.putJson('/me/password', {
      'password': password,
      'current': ?current,
    });
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  Future<void> _signedIn(Map<String, dynamic> res) async {
    // Número de um agente: falta a senha para abrir a sessão.
    if (res['agentTicket'] is String) {
      agentTicket = res['agentTicket'] as String;
      agentHasPassword = res['agentHasPassword'] == true;
      notifyListeners();
      return;
    }
    api.token = res['token'] as String;
    user = User.fromJson(res['user'] as Map<String, dynamic>);
    phoneRecovered = res['phoneRecovered'] == true;
    await _storage.write(key: 'token', value: api.token);
    _connect();
    _registerPush();
    notifyListeners();
  }

  Future<void> updateProfile({
    String? name,
    String? email,
    Vehicle? vehicle,
    License? license,
  }) async {
    final res = await api.patch('/me', {
      'name': ?name,
      'email': ?email,
      if (vehicle != null) 'vehicle': vehicle.toJson(),
      if (license != null) 'license': license.toJson(),
    });
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  /// Define o contacto de emergência; com [phone] null, remove-o.
  Future<void> setEmergencyContact({String? name, String? phone}) async {
    final res = await api.patch('/me', {
      'emergencyContact': phone == null ? null : {'name': name, 'phone': phone},
    });
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  /// Pede o código SMS para o número novo. Em desenvolvimento a API devolve-o.
  Future<String?> requestPhoneChange(String phone) async {
    final res = await api.post('/me/phone/request', {'phone': phone});
    return res['devCode'] as String?;
  }

  Future<void> confirmPhoneChange(String phone, String code) async {
    final res = await api.post('/me/phone/verify', {
      'phone': phone,
      'code': code,
    });
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  Future<void> uploadPhoto(List<int> bytes, String contentType) async {
    final res = await api.putBytes('/me/photo', bytes, contentType);
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  /// Envia a foto de um documento do motorista (carta ou livrete).
  Future<void> uploadDocument(
    String path,
    List<int> bytes,
    String contentType,
  ) async {
    final res = await api.putBytes(path, bytes, contentType);
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  Future<void> removePhoto() async {
    final res = await api.delete('/me/photo');
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  Future<void> refreshUser() async {
    final res = await api.get('/me');
    setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  void setUser(User u) {
    user = u;
    notifyListeners();
  }

  /// Elimina a conta no servidor e termina a sessão neste aparelho.
  Future<void> deleteAccount() async {
    await api.delete('/me');
    _socket?.dispose();
    _socket = null;
    api.token = null;
    user = null;
    await _storage.delete(key: 'token');
    notifyListeners();
  }

  // ── Notificações push ─────────────────────────────────────────────────────
  String? _pushToken;
  bool _pushListening = false;

  /// Diz ao servidor que este dispositivo recebe os avisos desta conta.
  Future<void> _registerPush() async {
    final token = await Push.token();
    if (token == null || api.token == null) return;
    _pushToken = token;
    try {
      await api.putJson(
        agent != null ? '/agent/push-token' : '/me/push-token',
        {'token': token},
      );
    } on ApiException {
      // Sem rede: volta a tentar no próximo arranque.
    }
    if (!_pushListening) {
      _pushListening = true;
      await Push.onTokenChange((_) => _registerPush());
    }
  }

  /// Ao sair, este dispositivo deixa de receber os avisos da conta.
  Future<void> _unregisterPush() async {
    final token = _pushToken;
    _pushToken = null;
    if (token == null || api.token == null) return;
    try {
      await api.post('/me/push-token/remove', {'token': token});
    } on ApiException {
      // O servidor remove o dispositivo quando um envio falhar.
    }
  }

  /// Há uma chamada em curso: a ligação mantém-se mesmo em segundo plano.
  bool inCall = false;

  /// Em segundo plano, o sistema pode congelar o app sem fechar a ligação, e o
  /// servidor continuaria a julgar que estamos a ver os avisos. Por isso a
  /// ligação fecha-se e os avisos passam a chegar por push. Excepções: o
  /// motorista online (o serviço de localização mantém o app vivo) e chamadas.
  void _onForegroundChanged(bool foreground) {
    final socket = _socket;
    if (socket == null || _pushToken == null) return;
    if (foreground) {
      if (!socket.connected) socket.connect();
    } else if (!(user?.isOnline ?? false) && !inCall) {
      socket.disconnect();
    }
  }

  Future<void> logout() async {
    if (agent != null) {
      try {
        await api.post('/agent/logout', {'token': ?_pushToken});
      } on ApiException {
        // Sem rede: a sessão termina na mesma neste telemóvel.
      }
      _pushToken = null;
      api.token = null;
      agent = null;
      await _storage.delete(key: 'agentToken');
      notifyListeners();
      return;
    }
    if (user?.isOnline ?? false) {
      try {
        await api.post('/driver/online', {'online': false});
      } on ApiException {
        // Sem rede: o servidor deixa de oferecer corridas quando a posição expira.
      }
    }
    await _unregisterPush();
    _socket?.dispose();
    _socket = null;
    api.token = null;
    user = null;
    await _storage.delete(key: 'token');
    notifyListeners();
  }

  // ── Tempo real ────────────────────────────────────────────────────────────
  /// Ouvintes registados pelos outros estados (corrida, motorista, chamada): voltam a ligar-se ao socket NOVO quando
  /// ele é recriado (ex.: mudou o servidor — escolha de servidor, 2026-11-27).
  final _ouvintes = <String, List<void Function(dynamic)>>{};
  bool _ouveServidor = false;

  /// Mudou o servidor (bazatranquilo.com ↔ angoschool.org/baza): com sessão aberta, o tempo real liga-se ao novo.
  void _servidorMudou() {
    if (_socket != null) _connect();
  }

  void _connect() {
    if (!_ouveServidor) {
      _ouveServidor = true;
      Servidores.activo.addListener(_servidorMudou);
    }
    _socket?.dispose();
    // Com o servidor sem saldo a API está num CAMINHO (angoschool.org/baza): o socket.io liga à origem com esse
    // prefixo no caminho (`/baza/socket.io`) — um caminho no endereço seria lido como «namespace».
    final base = Uri.parse(apiBaseUrl);
    final prefixo = base.path.replaceAll(RegExp(r'/+$'), '');
    _socket = sio.io(
      base.origin,
      sio.OptionBuilder()
          .setPath('$prefixo/socket.io')
          .setTransports(['websocket'])
          .setAuth({'token': api.token})
          .enableForceNew()
          .disableAutoConnect()
          .build(),
    )..connect();
    // O servidor avisa quando a conta muda (ex.: documentos aprovados ou rejeitados).
    _socket!.on('account:update', (_) => refreshUser().catchError((_) {}));
    for (final e in _ouvintes.entries) {
      for (final h in e.value) {
        _socket!.on(e.key, h);
      }
    }
  }

  void on(String event, void Function(dynamic) handler) {
    (_ouvintes[event] ??= []).add(handler);
    _socket?.on(event, handler);
  }

  void off(String event, void Function(dynamic) handler) {
    _ouvintes[event]?.remove(handler);
    _socket?.off(event, handler);
  }
  void emit(String event, Map<String, dynamic> data) {
    if (_socket?.connected ?? false) _socket!.emit(event, data);
  }

  bool get socketConnected => _socket?.connected ?? false;
}
