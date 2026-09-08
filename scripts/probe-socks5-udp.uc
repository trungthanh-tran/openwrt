#!/usr/bin/ucode
// Verify that a SOCKS5 endpoint can relay UDP, not merely carry TCP/HTTPS.
// The TCP control socket remains open while a STUN binding request traverses
// the UDP association.  Output is one JSON object and credentials are never
// included in it.

import * as socket from 'socket';
import * as struct from 'struct';

const host = ARGV[0];
const port = +ARGV[1];
const user = ARGV[2] || '';
const pass = ARGV[3] || '';
const stun_host = ARGV[4] || '74.125.250.129';
const stun_port = +(ARGV[5] || 19302);
const timeout_ms = +(ARGV[6] || 5000);

function finish(ok, error, relay) {
  print(sprintf('%.J\n', {
    ok,
    udp_state: ok ? 'ok' : 'fail',
    error: error || '',
    relay: relay || ''
  }));
  exit(ok ? 0 : 1);
}

function socket_error(s) {
  const e = s ? s.error() : socket.error();
  return e ? sprintf('%s', e) : 'socket error';
}

function recv_exact(s, wanted) {
  let data = '';
  while (length(data) < wanted) {
    const ready = socket.poll(timeout_ms, s);
    if (!ready || !length(ready) || !(ready[0][1] & socket.POLLIN)) return null;
    const part = s.recv(wanted - length(data));
    if (part == null || !length(part)) return null;
    data += part;
  }
  return data;
}

if (!host || !port || port < 1 || port > 65535)
  finish(false, 'invalid SOCKS5 endpoint');
if (length(user) > 255 || length(pass) > 255)
  finish(false, 'SOCKS5 username/password is longer than 255 bytes');

const tcp = socket.connect(host, port, { socktype: socket.SOCK_STREAM }, timeout_ms);
if (!tcp) finish(false, `TCP connect failed: ${socket_error(null)}`);

// Offer no-auth and username/password when credentials exist.  Accepting
// no-auth is valid even when credentials were supplied by the operator.
const greeting = user
  ? struct.pack('!BBBB', 5, 2, 0, 2)
  : struct.pack('!BBB', 5, 1, 0);
if (tcp.send(greeting) != length(greeting))
  finish(false, `SOCKS5 greeting failed: ${socket_error(tcp)}`);
let answer = recv_exact(tcp, 2);
if (!answer) finish(false, 'SOCKS5 greeting timed out');
let fields = struct.unpack('!BB', answer);
if (fields[0] != 5 || fields[1] == 255)
  finish(false, 'SOCKS5 server rejected all authentication methods');

if (fields[1] == 2) {
  if (!user) finish(false, 'SOCKS5 server requires username/password');
  const auth = struct.pack('!BB*B*', 1, length(user), user, length(pass), pass);
  if (tcp.send(auth) != length(auth))
    finish(false, `SOCKS5 authentication write failed: ${socket_error(tcp)}`);
  answer = recv_exact(tcp, 2);
  if (!answer) finish(false, 'SOCKS5 authentication timed out');
  fields = struct.unpack('!BB', answer);
  if (fields[0] != 1 || fields[1] != 0)
    finish(false, 'SOCKS5 username/password was rejected');
}
else if (fields[1] != 0) {
  finish(false, `unsupported SOCKS5 authentication method ${fields[1]}`);
}

// UDP ASSOCIATE, with 0.0.0.0:0 telling the proxy to use the source of the
// UDP packet.  RFC 1928 requires the TCP control connection to stay open.
const associate = struct.pack('!BBBBBBBBH', 5, 3, 0, 1, 0, 0, 0, 0, 0);
if (tcp.send(associate) != length(associate))
  finish(false, `UDP ASSOCIATE write failed: ${socket_error(tcp)}`);
answer = recv_exact(tcp, 4);
if (!answer) finish(false, 'UDP ASSOCIATE timed out');
fields = struct.unpack('!BBBB', answer);
if (fields[0] != 5 || fields[1] != 0)
  finish(false, `UDP ASSOCIATE was rejected (SOCKS5 reply ${fields[1]})`);

let relay_host;
if (fields[3] == 1) {
  const raw = recv_exact(tcp, 4);
  if (!raw) finish(false, 'truncated IPv4 UDP relay address');
  const octets = struct.unpack('!BBBB', raw);
  relay_host = join('.', octets);
}
else if (fields[3] == 3) {
  const raw_len = recv_exact(tcp, 1);
  if (!raw_len) finish(false, 'truncated domain UDP relay address');
  const n = struct.unpack('!B', raw_len)[0];
  relay_host = recv_exact(tcp, n);
  if (!relay_host) finish(false, 'truncated domain UDP relay address');
}
else {
  finish(false, `unsupported UDP relay address type ${fields[3]}`);
}
const raw_port = recv_exact(tcp, 2);
if (!raw_port) finish(false, 'truncated UDP relay port');
const relay_port = struct.unpack('!H', raw_port)[0];
if (relay_host == '0.0.0.0') relay_host = host;
if (!relay_port) finish(false, 'SOCKS5 server returned UDP relay port 0');

const udp = socket.connect(relay_host, relay_port, { socktype: socket.SOCK_DGRAM }, timeout_ms);
if (!udp) finish(false, `UDP relay connect failed: ${socket_error(null)}`);

const target = split(stun_host, '.');
if (length(target) != 4)
  finish(false, 'STUN probe currently requires an IPv4 target');
for (let octet in target)
  if (+octet < 0 || +octet > 255) finish(false, 'invalid STUN IPv4 target');

// Fixed transaction bytes are sufficient here: matching them prevents an
// unrelated datagram from producing a false pass, while no uniqueness or
// secrecy is required for this one-shot health check.
const txid = struct.pack('X', '736270726f78797564703031'); // sbproxyudp01
const stun = struct.pack('!HHI*', 1, 0, 0x2112a442, txid);
const packet = struct.pack('!BBBBBBBBH*',
  0, 0, 0, 1, +target[0], +target[1], +target[2], +target[3], stun_port,
  stun);
if (udp.send(packet) != length(packet))
  finish(false, `STUN datagram write failed: ${socket_error(udp)}`);

const ready = socket.poll(timeout_ms, udp);
if (!ready || !length(ready)) finish(false, 'UDP relay accepted ASSOCIATE but STUN timed out');
const response = udp.recv(2048);
if (!response || length(response) < 30)
  finish(false, 'UDP relay returned a truncated response');
const header = struct.unpack('!BBBB', substr(response, 0, 4));
if (header[0] != 0 || header[1] != 0 || header[2] != 0)
  finish(false, 'invalid SOCKS5 UDP response header');
let payload_offset;
if (header[3] == 1) payload_offset = 10;
else if (header[3] == 3) payload_offset = 7 + struct.unpack('!B', substr(response, 4, 1))[0];
else if (header[3] == 4) payload_offset = 22;
else finish(false, `unsupported SOCKS5 UDP response address type ${header[3]}`);
if (length(response) < payload_offset + 20)
  finish(false, 'SOCKS5 UDP response has no complete STUN message');
const stun_reply = substr(response, payload_offset);
const stun_head = struct.unpack('!HHI', substr(stun_reply, 0, 8));
if (stun_head[0] != 0x0101 || stun_head[2] != 0x2112a442 || substr(stun_reply, 8, 12) != txid)
  finish(false, 'UDP relay response did not match the STUN request');

finish(true, '', `${relay_host}:${relay_port}`);
