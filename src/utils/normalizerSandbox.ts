export interface ParsedNode {
  name: string;
  protocol: 'vless' | 'hysteria2' | 'trojan' | 'vmess' | 'shadowsocks' | 'wireguard' | 'socks5' | 'http';
  host: string;
  port: number;
  uuidOrPassword?: string;
  username?: string;
  method?: string;
  encryption?: string;
  flow?: string;
  network: string;
  path?: string;
  hostHeader?: string;
  xhttpMode?: string;
  xhttpExtra?: Record<string, unknown>;
  grpcServiceName?: string;
  grpcAuthority?: string;
  grpcMultiMode?: boolean;
  security: string;
  sni?: string;
  fingerprint?: string;
  alpn?: string[];
  allowInsecure?: boolean;
  realityPublicKey?: string;
  realityShortId?: string;
  realitySpiderX?: string;
  hy2Obfs?: string;
  hy2ObfsPassword?: string;
  wgPrivateKey?: string;
  wgPeerPublicKey?: string;
  wgPreSharedKey?: string;
  wgAddresses?: string[];
  wgReserved?: number[];
  wgMTU?: number;
}

export interface NormalizedNodeOutput {
  node: ParsedNode;
  badge: string;
  standardURI: string;
  strictXrayJSON: string;
  strippedFields: string[];
}

function decodeBase64Flexible(input: string): string | null {
  try {
    let cleaned = input.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
    const rem = cleaned.length % 4;
    if (rem > 0) cleaned += '='.repeat(4 - rem);
    const bin = atob(cleaned);
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
}

function normalizeNetwork(raw?: string): string {
  const n = (raw || '').trim().toLowerCase();
  if (!n || n === 'tcp' || n === 'raw') return 'raw';
  if (n === 'splithttp' || n === 'xhttp') return 'xhttp';
  if (n === 'ws' || n === 'websocket') return 'ws';
  if (n === 'grpc') return 'grpc';
  if (n === 'httpupgrade') return 'httpupgrade';
  return 'raw';
}

function formatHost(host: string): string {
  return host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
}

export function getNodeBadge(n: ParsedNode): string {
  const parts: string[] = [];
  if (n.protocol === 'vless') {
    parts.push('VLESS');
    if (n.security === 'reality') parts.push('REALITY');
    else if (n.security === 'tls') parts.push('TLS');
    if (n.flow?.toLowerCase().includes('vision')) parts.push('Vision');
    if (n.network && n.network !== 'raw') parts.push(n.network.toUpperCase());
  } else if (n.protocol === 'hysteria2') {
    parts.push('HY2');
    if (n.hy2Obfs) parts.push('OBFS');
  } else if (n.protocol === 'shadowsocks') {
    parts.push(n.method?.startsWith('2022-') ? 'SS-2022' : 'SS');
  } else {
    parts.push(n.protocol.toUpperCase());
    if (n.network && n.network !== 'raw') parts.push(n.network.toUpperCase());
  }
  return parts.join(' · ');
}

export function nodeToStandardURI(n: ParsedNode): string {
  const host = formatHost(n.host);
  const tag = encodeURIComponent(n.name || `${n.host}:${n.port}`);

  if (n.protocol === 'vless' || n.protocol === 'trojan') {
    const q = new URLSearchParams();
    if (n.protocol === 'vless') q.set('encryption', n.encryption || 'none');
    if (n.flow) q.set('flow', n.flow);
    if (n.security) q.set('security', n.security);
    if (n.sni) q.set('sni', n.sni);
    if (n.fingerprint) q.set('fp', n.fingerprint);
    if (n.alpn?.length) q.set('alpn', n.alpn.join(','));
    if (n.allowInsecure) q.set('allowInsecure', '1');
    if (n.security === 'reality') {
      if (n.realityPublicKey) q.set('pbk', n.realityPublicKey);
      if (n.realityShortId !== undefined) q.set('sid', n.realityShortId);
      if (n.realitySpiderX) q.set('spx', n.realitySpiderX);
    }
    const net = n.network === 'raw' ? 'tcp' : n.network;
    q.set('type', net);
    if (net === 'xhttp') {
      if (n.path) q.set('path', n.path);
      if (n.hostHeader) q.set('host', n.hostHeader);
      if (n.xhttpMode) q.set('mode', n.xhttpMode);
      if (n.xhttpExtra) q.set('extra', JSON.stringify(n.xhttpExtra));
    } else if (net === 'ws' || net === 'httpupgrade') {
      if (n.path) q.set('path', n.path);
      if (n.hostHeader) q.set('host', n.hostHeader);
    } else if (net === 'grpc') {
      if (n.grpcServiceName) q.set('serviceName', n.grpcServiceName);
      if (n.grpcAuthority) q.set('authority', n.grpcAuthority);
      q.set('mode', n.grpcMultiMode ? 'multi' : 'gun');
    }
    return `${n.protocol}://${encodeURIComponent(n.uuidOrPassword || '')}@${host}:${n.port}?${q.toString()}#${tag}`;
  }

  if (n.protocol === 'hysteria2') {
    const q = new URLSearchParams();
    if (n.sni) q.set('sni', n.sni);
    if (n.allowInsecure) q.set('insecure', '1');
    if (n.hy2Obfs) q.set('obfs', n.hy2Obfs);
    if (n.hy2ObfsPassword) q.set('obfs-password', n.hy2ObfsPassword);
    const qs = q.toString();
    return `hysteria2://${encodeURIComponent(n.uuidOrPassword || '')}@${host}:${n.port}${qs ? '?' + qs : ''}#${tag}`;
  }

  if (n.protocol === 'shadowsocks') {
    const cred = btoa(`${n.method || 'aes-256-gcm'}:${n.uuidOrPassword || ''}`);
    return `ss://${cred}@${host}:${n.port}#${tag}`;
  }

  if (n.protocol === 'vmess') {
    const payload = {
      v: '2',
      ps: n.name,
      add: n.host,
      port: n.port,
      id: n.uuidOrPassword || '',
      aid: 0,
      scy: n.method || 'auto',
      net: n.network === 'raw' ? 'tcp' : n.network,
      type: 'none',
      host: n.hostHeader || '',
      path: n.path || '',
      tls: n.security === 'tls' ? 'tls' : '',
      sni: n.sni || '',
      fp: n.fingerprint || 'chrome',
    };
    return `vmess://${btoa(unescape(encodeURIComponent(JSON.stringify(payload))))}`;
  }

  if (n.protocol === 'wireguard') {
    const q = new URLSearchParams();
    if (n.wgPeerPublicKey) q.set('publickey', n.wgPeerPublicKey);
    if (n.wgPreSharedKey) q.set('presharedkey', n.wgPreSharedKey);
    if (n.wgAddresses?.length) q.set('address', n.wgAddresses.join(','));
    if (n.wgReserved?.length === 3) q.set('reserved', n.wgReserved.join(','));
    if (n.wgMTU) q.set('mtu', String(n.wgMTU));
    return `wireguard://${encodeURIComponent(n.wgPrivateKey || '')}@${host}:${n.port}?${q.toString()}#${tag}`;
  }

  return `${n.protocol}://${host}:${n.port}#${tag}`;
}

export function buildStrictXrayJSON(node: ParsedNode, socksPort = 10808, httpPort = 10809): string {
  const buildStream = () => {
    const stream: Record<string, unknown> = {
      network: normalizeNetwork(node.network),
      security: node.security || 'none',
    };
    if (node.security === 'reality') {
      const r: Record<string, unknown> = {
        fingerprint: node.fingerprint || 'chrome',
        shortId: node.realityShortId || '',
      };
      if (node.sni) r.serverName = node.sni;
      if (node.realityPublicKey) r.publicKey = node.realityPublicKey;
      if (node.realitySpiderX) r.spiderX = node.realitySpiderX;
      stream.realitySettings = r;
    } else if (node.security === 'tls') {
      const t: Record<string, unknown> = {};
      if (node.sni) t.serverName = node.sni;
      if (node.fingerprint) t.fingerprint = node.fingerprint;
      if (node.alpn?.length) t.alpn = node.alpn;
      if (node.allowInsecure) t.allowInsecure = true;
      stream.tlsSettings = t;
    }
    if (node.network === 'xhttp') {
      const x: Record<string, unknown> = {
        path: node.path || '/',
        mode: node.xhttpMode || 'auto',
      };
      if (node.hostHeader) x.host = node.hostHeader;
      if (node.xhttpExtra) x.extra = node.xhttpExtra;
      stream.xhttpSettings = x;
    } else if (node.network === 'ws') {
      const ws: Record<string, unknown> = { path: node.path || '/' };
      if (node.hostHeader) ws.headers = { Host: node.hostHeader };
      stream.wsSettings = ws;
    } else if (node.network === 'httpupgrade') {
      const hu: Record<string, unknown> = { path: node.path || '/' };
      if (node.hostHeader) hu.host = node.hostHeader;
      stream.httpupgradeSettings = hu;
    } else if (node.network === 'grpc') {
      const gr: Record<string, unknown> = { serviceName: node.grpcServiceName || '' };
      if (node.grpcAuthority) gr.authority = node.grpcAuthority;
      if (node.grpcMultiMode) gr.multiMode = true;
      stream.grpcSettings = gr;
    }
    return stream;
  };

  let outbound: Record<string, unknown> = {};
  if (node.protocol === 'vless') {
    const user: Record<string, unknown> = {
      id: node.uuidOrPassword || '',
      encryption: node.encryption || 'none',
    };
    if (node.flow) user.flow = node.flow;
    outbound = {
      tag: 'proxy',
      protocol: 'vless',
      settings: { vnext: [{ address: node.host, port: node.port, users: [user] }] },
      streamSettings: buildStream(),
    };
  } else if (node.protocol === 'trojan') {
    outbound = {
      tag: 'proxy',
      protocol: 'trojan',
      settings: { servers: [{ address: node.host, port: node.port, password: node.uuidOrPassword || '' }] },
      streamSettings: buildStream(),
    };
  } else if (node.protocol === 'vmess') {
    outbound = {
      tag: 'proxy',
      protocol: 'vmess',
      settings: {
        vnext: [{
          address: node.host,
          port: node.port,
          users: [{ id: node.uuidOrPassword || '', security: node.method || 'auto' }],
        }],
      },
      streamSettings: buildStream(),
    };
  } else if (node.protocol === 'shadowsocks') {
    outbound = {
      tag: 'proxy',
      protocol: 'shadowsocks',
      settings: {
        servers: [{
          address: node.host,
          port: node.port,
          method: node.method || 'aes-256-gcm',
          password: node.uuidOrPassword || '',
        }],
      },
    };
  } else if (node.protocol === 'hysteria2') {
    const settings: Record<string, unknown> = {
      address: node.host,
      port: node.port,
      password: node.uuidOrPassword || '',
    };
    if (node.hy2Obfs && node.hy2ObfsPassword) {
      settings.obfs = { type: node.hy2Obfs, password: node.hy2ObfsPassword };
    }
    const tls: Record<string, unknown> = {};
    if (node.sni) tls.serverName = node.sni;
    if (node.allowInsecure) tls.allowInsecure = true;
    outbound = {
      tag: 'proxy',
      protocol: 'hysteria2',
      settings,
      streamSettings: { security: 'tls', tlsSettings: tls },
    };
  } else if (node.protocol === 'wireguard') {
    outbound = {
      tag: 'proxy',
      protocol: 'wireguard',
      settings: {
        secretKey: node.wgPrivateKey || '',
        address: node.wgAddresses?.length ? node.wgAddresses : ['10.0.0.2/32'],
        mtu: node.wgMTU || 1280,
        ...(node.wgReserved?.length === 3 ? { reserved: node.wgReserved } : {}),
        peers: [{
          endpoint: `${node.host}:${node.port}`,
          ...(node.wgPeerPublicKey ? { publicKey: node.wgPeerPublicKey } : {}),
          ...(node.wgPreSharedKey ? { preSharedKey: node.wgPreSharedKey } : {}),
        }],
      },
    };
  } else {
    outbound = {
      tag: 'proxy',
      protocol: node.protocol === 'socks5' ? 'socks' : 'http',
      settings: { servers: [{ address: node.host, port: node.port }] },
    };
  }

  return JSON.stringify(
    {
      log: { loglevel: 'warning' },
      inbounds: [
        { tag: 'socks-in', listen: '127.0.0.1', port: socksPort, protocol: 'socks', settings: { udp: true } },
        { tag: 'http-in', listen: '127.0.0.1', port: httpPort, protocol: 'http', settings: {} },
      ],
      outbounds: [outbound, { tag: 'direct', protocol: 'freedom' }],
    },
    null,
    2,
  );
}

function parseSingleURI(raw: string): ParsedNode | null {
  const s = raw.trim();
  const lower = s.toLowerCase();

  if (lower.startsWith('vless://') || lower.startsWith('trojan://')) {
    try {
      const u = new URL(s);
      const q = u.searchParams;
      const protocol = lower.startsWith('vless://') ? 'vless' : 'trojan';
      const net = normalizeNetwork(q.get('type') || q.get('net') || undefined);
      let extra: Record<string, unknown> | undefined;
      if (q.get('extra')) {
        try {
          extra = JSON.parse(q.get('extra')!);
        } catch {
          // ignore malformed extra
        }
      }
      return {
        name: u.hash ? decodeURIComponent(u.hash.slice(1)) : `${u.hostname}:${u.port}`,
        protocol,
        host: u.hostname,
        port: Number(u.port) || 443,
        uuidOrPassword: decodeURIComponent(u.username),
        encryption: protocol === 'vless' ? q.get('encryption') || 'none' : undefined,
        flow: q.get('flow') || undefined,
        network: net,
        path: q.get('path') || undefined,
        hostHeader: q.get('host') || undefined,
        xhttpMode: net === 'xhttp' ? q.get('mode') || 'auto' : undefined,
        xhttpExtra: extra,
        grpcServiceName: net === 'grpc' ? q.get('serviceName') || q.get('path') || undefined : undefined,
        grpcAuthority: net === 'grpc' ? q.get('authority') || q.get('host') || undefined : undefined,
        grpcMultiMode: net === 'grpc' ? q.get('mode') === 'multi' : undefined,
        security: (q.get('security') || (protocol === 'trojan' ? 'tls' : 'none')).toLowerCase(),
        sni: q.get('sni') || q.get('peer') || undefined,
        fingerprint: q.get('fp') || 'chrome',
        alpn: q.get('alpn') ? q.get('alpn')!.split(',') : undefined,
        allowInsecure: q.get('allowInsecure') === '1' || q.get('insecure') === '1',
        realityPublicKey: q.get('pbk') || undefined,
        realityShortId: q.get('sid') ?? undefined,
        realitySpiderX: q.get('spx') || undefined,
      };
    } catch {
      return null;
    }
  }

  if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
    try {
      const norm = lower.startsWith('hy2://') ? 'hysteria2://' + s.slice(6) : s;
      const u = new URL(norm);
      const q = u.searchParams;
      return {
        name: u.hash ? decodeURIComponent(u.hash.slice(1)) : `HY2 ${u.hostname}:${u.port}`,
        protocol: 'hysteria2',
        host: u.hostname,
        port: Number(u.port) || 443,
        uuidOrPassword: u.password ? `${decodeURIComponent(u.username)}:${decodeURIComponent(u.password)}` : decodeURIComponent(u.username),
        network: 'raw',
        security: 'tls',
        sni: q.get('sni') || u.hostname,
        allowInsecure: q.get('insecure') === '1',
        hy2Obfs: q.get('obfs') || undefined,
        hy2ObfsPassword: q.get('obfs-password') || undefined,
      };
    } catch {
      return null;
    }
  }

  if (lower.startsWith('ss://')) {
    try {
      let body = s.slice(5);
      let name = '';
      const hashIdx = body.indexOf('#');
      if (hashIdx >= 0) {
        name = decodeURIComponent(body.slice(hashIdx + 1));
        body = body.slice(0, hashIdx);
      }
      const atIdx = body.lastIndexOf('@');
      if (atIdx >= 0) {
        const userPart = body.slice(0, atIdx);
        const hostPort = body.slice(atIdx + 1);
        const decoded = userPart.includes(':') ? decodeURIComponent(userPart) : decodeBase64Flexible(userPart) || '';
        const colon = decoded.indexOf(':');
        const u = new URL(`http://${hostPort}`);
        if (colon > 0) {
          return {
            name: name || `SS ${u.hostname}:${u.port}`,
            protocol: 'shadowsocks',
            host: u.hostname,
            port: Number(u.port),
            method: decoded.slice(0, colon),
            uuidOrPassword: decoded.slice(colon + 1),
            network: 'raw',
            security: 'none',
          };
        }
      }
    } catch {
      return null;
    }
  }

  return null;
}

const UNSUPPORTED_XRAY_ROOT_KEYS = ['observatory', 'burstObservatory', 'fakedns', 'stats', 'api', 'metrics', 'policy', 'reverse', 'transport'];

function parseJSONPayload(raw: string): { nodes: ParsedNode[]; stripped: string[] } {
  const parsed = JSON.parse(raw);
  const items = Array.isArray(parsed) ? parsed : [parsed];
  const nodes: ParsedNode[] = [];
  const strippedSet = new Set<string>();

  for (const obj of items) {
    if (!obj || typeof obj !== 'object') continue;
    for (const k of UNSUPPORTED_XRAY_ROOT_KEYS) {
      if (k in obj) strippedSet.add(k);
    }
    const outbounds = Array.isArray(obj.outbounds) ? obj.outbounds : [obj];
    for (const ob of outbounds) {
      if (!ob || typeof ob !== 'object') continue;
      // Xray outbound
      if (typeof ob.protocol === 'string') {
        const proto = ob.protocol.toLowerCase();
        if (['freedom', 'blackhole', 'dns', 'direct', 'block'].includes(proto)) continue;
        const st = ob.settings || {};
        const ss = ob.streamSettings || {};
        if ('mux' in ob) strippedSet.add('outbound.mux');
        if ('sendThrough' in ob) strippedSet.add('outbound.sendThrough');

        let host = '';
        let port = 0;
        let uuidOrPassword = '';
        let encryption = 'none';
        let flow: string | undefined;
        let method: string | undefined;

        if (proto === 'vless' || proto === 'vmess') {
          const srv = st.vnext?.[0];
          const usr = srv?.users?.[0];
          host = srv?.address || '';
          port = Number(srv?.port) || 0;
          uuidOrPassword = usr?.id || '';
          encryption = usr?.encryption || 'none';
          flow = usr?.flow;
          method = usr?.security;
        } else if (proto === 'trojan' || proto === 'shadowsocks') {
          const srv = st.servers?.[0];
          host = srv?.address || '';
          port = Number(srv?.port) || 0;
          uuidOrPassword = srv?.password || '';
          method = srv?.method;
        } else if (proto === 'hysteria2') {
          host = st.address || st.server || '';
          port = Number(st.port) || 0;
          uuidOrPassword = st.password || st.auth || '';
        }

        if (!host || !port) continue;
        const net = normalizeNetwork(ss.network);
        const sec = (ss.security || 'none').toLowerCase();
        const xhttp = ss.xhttpSettings || ss.splithttpSettings;
        nodes.push({
          name: obj.remarks || ob.tag || `${proto.toUpperCase()} ${host}:${port}`,
          protocol: proto as ParsedNode['protocol'],
          host,
          port,
          uuidOrPassword,
          encryption,
          flow,
          method,
          network: net,
          path: xhttp?.path || ss.wsSettings?.path || ss.httpupgradeSettings?.path,
          hostHeader: xhttp?.host || ss.wsSettings?.headers?.Host || ss.httpupgradeSettings?.host,
          xhttpMode: xhttp?.mode,
          xhttpExtra: xhttp?.extra,
          grpcServiceName: ss.grpcSettings?.serviceName,
          grpcAuthority: ss.grpcSettings?.authority,
          grpcMultiMode: Boolean(ss.grpcSettings?.multiMode),
          security: sec,
          sni: ss.realitySettings?.serverName || ss.tlsSettings?.serverName,
          fingerprint: ss.realitySettings?.fingerprint || ss.tlsSettings?.fingerprint || 'chrome',
          realityPublicKey: ss.realitySettings?.publicKey || ss.realitySettings?.password,
          realityShortId: ss.realitySettings?.shortId,
          realitySpiderX: ss.realitySettings?.spiderX,
          alpn: ss.tlsSettings?.alpn,
          allowInsecure: Boolean(ss.tlsSettings?.allowInsecure),
        });
      } else if (typeof ob.type === 'string') {
        // sing-box outbound
        const t = ob.type.toLowerCase();
        if (['direct', 'block', 'dns', 'selector', 'urltest'].includes(t)) continue;
        if (!ob.server || !ob.server_port) continue;
        const tls = ob.tls || {};
        const reality = tls.reality || {};
        const tr = ob.transport || {};
        nodes.push({
          name: ob.tag || `${t.toUpperCase()} ${ob.server}:${ob.server_port}`,
          protocol: (t === 'socks' ? 'socks5' : t) as ParsedNode['protocol'],
          host: ob.server,
          port: Number(ob.server_port),
          uuidOrPassword: ob.uuid || ob.password,
          flow: ob.flow,
          method: ob.method || ob.security,
          network: normalizeNetwork(tr.type),
          path: tr.path,
          hostHeader: tr.host || tr.headers?.Host,
          grpcServiceName: tr.service_name,
          security: tls.enabled ? (reality.enabled ? 'reality' : 'tls') : 'none',
          sni: tls.server_name,
          fingerprint: tls.utls?.fingerprint || 'chrome',
          realityPublicKey: reality.public_key,
          realityShortId: reality.short_id,
          allowInsecure: Boolean(tls.insecure),
          hy2Obfs: ob.obfs?.type,
          hy2ObfsPassword: ob.obfs?.password,
        });
      }
    }
  }
  return { nodes, stripped: Array.from(strippedSet) };
}

export function runNormalizerSandbox(rawInput: string): { results: NormalizedNodeOutput[]; error?: string } {
  const trimmed = rawInput.trim();
  if (!trimmed) return { results: [], error: 'Вставьте URI-ключ, Base64-подписку или сырой Xray / sing-box JSON.' };

  try {
    let nodes: ParsedNode[] = [];
    let stripped: string[] = [];

    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      const res = parseJSONPayload(trimmed);
      nodes = res.nodes;
      stripped = res.stripped;
    } else {
      const lines = trimmed.split(/\r?\n/);
      for (const line of lines) {
        const n = parseSingleURI(line);
        if (n) nodes.push(n);
      }
      if (nodes.length === 0) {
        const decoded = decodeBase64Flexible(trimmed);
        if (decoded) {
          const dt = decoded.trim();
          if (dt.startsWith('{') || dt.startsWith('[')) {
            const res = parseJSONPayload(dt);
            nodes = res.nodes;
            stripped = res.stripped;
          } else {
            for (const line of dt.split(/\r?\n/)) {
              const n = parseSingleURI(line);
              if (n) nodes.push(n);
            }
          }
        }
      }
    }

    if (nodes.length === 0) {
      return { results: [], error: 'Не удалось распознать поддерживаемые узлы (VLESS, Hysteria2, Trojan, VMess, SS, WireGuard, Xray/sing-box JSON).' };
    }

    return {
      results: nodes.map((node) => ({
        node,
        badge: getNodeBadge(node),
        standardURI: nodeToStandardURI(node),
        strictXrayJSON: buildStrictXrayJSON(node),
        strippedFields: stripped,
      })),
    };
  } catch (e) {
    return {
      results: [],
      error: e instanceof Error ? `Ошибка разбора: ${e.message}` : 'Неверный формат входных данных',
    };
  }
}
