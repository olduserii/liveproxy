#import "LCProxyNode.h"

static NSString *lc_percentEncode(NSString *str) {
    if (str.length == 0) return @"";
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=?+#%/:@"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: str;
}

static NSString *lc_fragmentEncode(NSString *str) {
    if (str.length == 0) return @"";
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLFragmentAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"#%"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: str;
}

static NSString *lc_formatHost(NSString *host) {
    if ([host containsString:@":"] && ![host hasPrefix:@"["]) {
        return [NSString stringWithFormat:@"[%@]", host];
    }
    return host ?: @"";
}

@implementation LCProxyNode

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodeID = [[NSUUID UUID] UUIDString];
        _name = @"Unnamed Node";
        _network = @"raw";
        _security = @"none";
        _encryption = @"none";
        _tcpPingMs = -1;
        _realPingMs = -1;
        _wgMTU = 1280;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    LCProxyNode *copy = [LCProxyNode nodeFromDictionary:[self toDictionary]];
    return copy ?: [[LCProxyNode alloc] init];
}

+ (NSString *)protocolNameForType:(LCProxyProtocol)protocol {
    switch (protocol) {
        case LCProxyProtocolVLESS:       return @"vless";
        case LCProxyProtocolHysteria2:   return @"hysteria2";
        case LCProxyProtocolTrojan:      return @"trojan";
        case LCProxyProtocolVMess:       return @"vmess";
        case LCProxyProtocolShadowsocks: return @"shadowsocks";
        case LCProxyProtocolWireGuard:   return @"wireguard";
        case LCProxyProtocolSOCKS5:      return @"socks5";
        case LCProxyProtocolHTTP:        return @"http";
        default:                         return @"unknown";
    }
}

+ (LCProxyProtocol)protocolTypeFromString:(NSString *)str {
    NSString *lower = [[str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"vless"]) return LCProxyProtocolVLESS;
    if ([lower isEqualToString:@"hysteria2"] || [lower isEqualToString:@"hy2"]) return LCProxyProtocolHysteria2;
    if ([lower isEqualToString:@"trojan"]) return LCProxyProtocolTrojan;
    if ([lower isEqualToString:@"vmess"]) return LCProxyProtocolVMess;
    if ([lower isEqualToString:@"shadowsocks"] || [lower isEqualToString:@"ss"]) return LCProxyProtocolShadowsocks;
    if ([lower isEqualToString:@"wireguard"] || [lower isEqualToString:@"wg"]) return LCProxyProtocolWireGuard;
    if ([lower isEqualToString:@"socks"] || [lower isEqualToString:@"socks5"]) return LCProxyProtocolSOCKS5;
    if ([lower isEqualToString:@"http"] || [lower isEqualToString:@"https"]) return LCProxyProtocolHTTP;
    return LCProxyProtocolUnknown;
}

- (NSString *)protocolBadgeText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    switch (self.protocol) {
        case LCProxyProtocolVLESS:
            [parts addObject:@"VLESS"];
            if ([self.security isEqualToString:@"reality"]) [parts addObject:@"REALITY"];
            else if ([self.security isEqualToString:@"tls"]) [parts addObject:@"TLS"];
            if (self.flow.length > 0 && [[self.flow lowercaseString] containsString:@"vision"]) {
                [parts addObject:@"Vision"];
            }
            if (self.network.length > 0 && ![self.network isEqualToString:@"raw"] && ![self.network isEqualToString:@"tcp"]) {
                [parts addObject:[self.network uppercaseString]];
            }
            break;
        case LCProxyProtocolHysteria2:
            [parts addObject:@"HY2"];
            if (self.hy2Obfs.length > 0) [parts addObject:@"OBFS"];
            break;
        case LCProxyProtocolTrojan:
            [parts addObject:@"Trojan"];
            if ([self.security isEqualToString:@"reality"]) [parts addObject:@"REALITY"];
            if (self.network.length > 0 && ![self.network isEqualToString:@"raw"] && ![self.network isEqualToString:@"tcp"]) {
                [parts addObject:[self.network uppercaseString]];
            }
            break;
        case LCProxyProtocolVMess:
            [parts addObject:@"VMess"];
            if (self.network.length > 0 && ![self.network isEqualToString:@"raw"] && ![self.network isEqualToString:@"tcp"]) {
                [parts addObject:[self.network uppercaseString]];
            }
            break;
        case LCProxyProtocolShadowsocks:
            if ([self.method hasPrefix:@"2022-"]) [parts addObject:@"SS-2022"];
            else [parts addObject:@"SS"];
            break;
        case LCProxyProtocolWireGuard:
            [parts addObject:@"WireGuard"];
            break;
        case LCProxyProtocolSOCKS5:
            [parts addObject:@"SOCKS5"];
            break;
        case LCProxyProtocolHTTP:
            [parts addObject:@"HTTP"];
            break;
        default:
            [parts addObject:@"PROXY"];
            break;
    }
    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)toURIString {
    NSString *formattedHost = lc_formatHost(self.host);
    NSString *tag = lc_fragmentEncode(self.name.length > 0 ? self.name : self.host);

    if (self.protocol == LCProxyProtocolVLESS || self.protocol == LCProxyProtocolTrojan) {
        NSString *scheme = (self.protocol == LCProxyProtocolVLESS) ? @"vless" : @"trojan";
        NSMutableArray<NSString *> *q = [NSMutableArray array];

        if (self.protocol == LCProxyProtocolVLESS) {
            NSString *enc = self.encryption.length > 0 ? self.encryption : @"none";
            [q addObject:[NSString stringWithFormat:@"encryption=%@", lc_percentEncode(enc)]];
        }
        if (self.flow.length > 0) {
            [q addObject:[NSString stringWithFormat:@"flow=%@", lc_percentEncode(self.flow)]];
        }
        if (self.security.length > 0) {
            [q addObject:[NSString stringWithFormat:@"security=%@", lc_percentEncode(self.security)]];
        }
        if (self.sni.length > 0) {
            [q addObject:[NSString stringWithFormat:@"sni=%@", lc_percentEncode(self.sni)]];
        }
        if (self.fingerprint.length > 0) {
            [q addObject:[NSString stringWithFormat:@"fp=%@", lc_percentEncode(self.fingerprint)]];
        }
        if (self.alpn.count > 0) {
            [q addObject:[NSString stringWithFormat:@"alpn=%@", lc_percentEncode([self.alpn componentsJoinedByString:@","])]];
        }
        if (self.allowInsecure) {
            [q addObject:@"allowInsecure=1"];
        }
        if ([self.security isEqualToString:@"reality"]) {
            if (self.realityPublicKey.length > 0) {
                [q addObject:[NSString stringWithFormat:@"pbk=%@", lc_percentEncode(self.realityPublicKey)]];
            }
            if (self.realityShortId.length > 0) {
                [q addObject:[NSString stringWithFormat:@"sid=%@", lc_percentEncode(self.realityShortId)]];
            }
            if (self.realitySpiderX.length > 0) {
                [q addObject:[NSString stringWithFormat:@"spx=%@", lc_percentEncode(self.realitySpiderX)]];
            }
        }

        NSString *net = (self.network.length > 0) ? self.network : @"tcp";
        if ([net isEqualToString:@"raw"]) net = @"tcp";
        [q addObject:[NSString stringWithFormat:@"type=%@", lc_percentEncode(net)]];

        if ([net isEqualToString:@"xhttp"] || [net isEqualToString:@"splithttp"]) {
            if (self.path.length > 0) [q addObject:[NSString stringWithFormat:@"path=%@", lc_percentEncode(self.path)]];
            if (self.hostHeader.length > 0) [q addObject:[NSString stringWithFormat:@"host=%@", lc_percentEncode(self.hostHeader)]];
            if (self.xhttpMode.length > 0) [q addObject:[NSString stringWithFormat:@"mode=%@", lc_percentEncode(self.xhttpMode)]];
            if (self.xhttpExtra.count > 0) {
                NSData *extraData = [NSJSONSerialization dataWithJSONObject:self.xhttpExtra options:0 error:nil];
                if (extraData) {
                    NSString *extraStr = [[NSString alloc] initWithData:extraData encoding:NSUTF8StringEncoding];
                    if (extraStr.length > 0) [q addObject:[NSString stringWithFormat:@"extra=%@", lc_percentEncode(extraStr)]];
                }
            }
        } else if ([net isEqualToString:@"ws"] || [net isEqualToString:@"httpupgrade"]) {
            if (self.path.length > 0) [q addObject:[NSString stringWithFormat:@"path=%@", lc_percentEncode(self.path)]];
            if (self.hostHeader.length > 0) [q addObject:[NSString stringWithFormat:@"host=%@", lc_percentEncode(self.hostHeader)]];
        } else if ([net isEqualToString:@"grpc"]) {
            if (self.grpcServiceName.length > 0) [q addObject:[NSString stringWithFormat:@"serviceName=%@", lc_percentEncode(self.grpcServiceName)]];
            if (self.grpcAuthority.length > 0) [q addObject:[NSString stringWithFormat:@"authority=%@", lc_percentEncode(self.grpcAuthority)]];
            [q addObject:[NSString stringWithFormat:@"mode=%@", self.grpcMultiMode ? @"multi" : @"gun"]];
        }

        NSString *cred = lc_percentEncode(self.uuidOrPassword ?: @"");
        return [NSString stringWithFormat:@"%@://%@@%@:%u?%@#%@",
                scheme, cred, formattedHost, self.port, [q componentsJoinedByString:@"&"], tag];
    }

    if (self.protocol == LCProxyProtocolHysteria2) {
        NSMutableArray<NSString *> *q = [NSMutableArray array];
        if (self.sni.length > 0) [q addObject:[NSString stringWithFormat:@"sni=%@", lc_percentEncode(self.sni)]];
        if (self.allowInsecure) [q addObject:@"insecure=1"];
        if (self.hy2Obfs.length > 0) [q addObject:[NSString stringWithFormat:@"obfs=%@", lc_percentEncode(self.hy2Obfs)]];
        if (self.hy2ObfsPassword.length > 0) [q addObject:[NSString stringWithFormat:@"obfs-password=%@", lc_percentEncode(self.hy2ObfsPassword)]];
        if (self.hy2PinSHA256.length > 0) [q addObject:[NSString stringWithFormat:@"pinSHA256=%@", lc_percentEncode(self.hy2PinSHA256)]];
        NSString *queryPart = q.count > 0 ? [@"?" stringByAppendingString:[q componentsJoinedByString:@"&"]] : @"";
        return [NSString stringWithFormat:@"hysteria2://%@@%@:%u%@#%@",
                lc_percentEncode(self.uuidOrPassword ?: @""), formattedHost, self.port, queryPart, tag];
    }

    if (self.protocol == LCProxyProtocolVMess) {
        NSMutableDictionary *vm = [NSMutableDictionary dictionary];
        vm[@"v"] = @"2";
        vm[@"ps"] = self.name ?: self.host ?: @"VMess";
        vm[@"add"] = self.host ?: @"";
        vm[@"port"] = @(self.port);
        vm[@"id"] = self.uuidOrPassword ?: @"";
        vm[@"aid"] = @(0);
        vm[@"scy"] = self.method.length > 0 ? self.method : @"auto";
        vm[@"net"] = ([self.network isEqualToString:@"raw"] || self.network.length == 0) ? @"tcp" : self.network;
        vm[@"type"] = @"none";
        if (self.hostHeader.length > 0) vm[@"host"] = self.hostHeader;
        if (self.path.length > 0) vm[@"path"] = self.path;
        vm[@"tls"] = [self.security isEqualToString:@"tls"] ? @"tls" : @"";
        if (self.sni.length > 0) vm[@"sni"] = self.sni;
        if (self.fingerprint.length > 0) vm[@"fp"] = self.fingerprint;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:vm options:0 error:nil];
        NSString *b64 = [jsonData base64EncodedStringWithOptions:0] ?: @"";
        return [NSString stringWithFormat:@"vmess://%@", b64];
    }

    if (self.protocol == LCProxyProtocolShadowsocks) {
        NSString *userInfo = [NSString stringWithFormat:@"%@:%@",
                              self.method ?: @"aes-256-gcm", self.uuidOrPassword ?: @""];
        NSString *encoded = [[userInfo dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        return [NSString stringWithFormat:@"ss://%@@%@:%u#%@", encoded, formattedHost, self.port, tag];
    }

    if (self.protocol == LCProxyProtocolWireGuard) {
        NSMutableArray<NSString *> *q = [NSMutableArray array];
        if (self.wgPeerPublicKey.length > 0) [q addObject:[NSString stringWithFormat:@"publickey=%@", lc_percentEncode(self.wgPeerPublicKey)]];
        if (self.wgPreSharedKey.length > 0) [q addObject:[NSString stringWithFormat:@"presharedkey=%@", lc_percentEncode(self.wgPreSharedKey)]];
        if (self.wgAddresses.count > 0) [q addObject:[NSString stringWithFormat:@"address=%@", lc_percentEncode([self.wgAddresses componentsJoinedByString:@","])]];
        if (self.wgReserved.count == 3) {
            [q addObject:[NSString stringWithFormat:@"reserved=%@,%@,%@", self.wgReserved[0], self.wgReserved[1], self.wgReserved[2]]];
        }
        if (self.wgMTU > 0) [q addObject:[NSString stringWithFormat:@"mtu=%ld", (long)self.wgMTU]];
        return [NSString stringWithFormat:@"wireguard://%@@%@:%u?%@#%@",
                lc_percentEncode(self.wgPrivateKey ?: @""), formattedHost, self.port, [q componentsJoinedByString:@"&"], tag];
    }

    if (self.protocol == LCProxyProtocolSOCKS5 || self.protocol == LCProxyProtocolHTTP) {
        NSString *scheme = (self.protocol == LCProxyProtocolSOCKS5) ? @"socks5" : @"http";
        if (self.username.length > 0 || self.uuidOrPassword.length > 0) {
            return [NSString stringWithFormat:@"%@://%@:%@@%@:%u#%@",
                    scheme,
                    lc_percentEncode(self.username ?: @""),
                    lc_percentEncode(self.uuidOrPassword ?: @""),
                    formattedHost, self.port, tag];
        }
        return [NSString stringWithFormat:@"%@://%@:%u#%@", scheme, formattedHost, self.port, tag];
    }

    return [NSString stringWithFormat:@"%@:%u", formattedHost, self.port];
}

- (NSDictionary<NSString *, id> *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"nodeID"] = self.nodeID ?: [[NSUUID UUID] UUIDString];
    d[@"name"] = self.name ?: @"";
    if (self.subscriptionID) d[@"subscriptionID"] = self.subscriptionID;
    d[@"protocol"] = [LCProxyNode protocolNameForType:self.protocol];
    d[@"host"] = self.host ?: @"";
    d[@"port"] = @(self.port);
    if (self.uuidOrPassword) d[@"uuidOrPassword"] = self.uuidOrPassword;
    if (self.username) d[@"username"] = self.username;
    if (self.method) d[@"method"] = self.method;
    if (self.encryption) d[@"encryption"] = self.encryption;
    if (self.flow) d[@"flow"] = self.flow;
    d[@"network"] = self.network ?: @"raw";
    if (self.path) d[@"path"] = self.path;
    if (self.hostHeader) d[@"hostHeader"] = self.hostHeader;
    if (self.xhttpMode) d[@"xhttpMode"] = self.xhttpMode;
    if (self.xhttpExtra) d[@"xhttpExtra"] = self.xhttpExtra;
    if (self.grpcServiceName) d[@"grpcServiceName"] = self.grpcServiceName;
    if (self.grpcAuthority) d[@"grpcAuthority"] = self.grpcAuthority;
    d[@"grpcMultiMode"] = @(self.grpcMultiMode);
    d[@"security"] = self.security ?: @"none";
    if (self.sni) d[@"sni"] = self.sni;
    if (self.fingerprint) d[@"fingerprint"] = self.fingerprint;
    if (self.alpn) d[@"alpn"] = self.alpn;
    d[@"allowInsecure"] = @(self.allowInsecure);
    if (self.realityPublicKey) d[@"realityPublicKey"] = self.realityPublicKey;
    if (self.realityShortId) d[@"realityShortId"] = self.realityShortId;
    if (self.realitySpiderX) d[@"realitySpiderX"] = self.realitySpiderX;
    if (self.hy2Obfs) d[@"hy2Obfs"] = self.hy2Obfs;
    if (self.hy2ObfsPassword) d[@"hy2ObfsPassword"] = self.hy2ObfsPassword;
    if (self.hy2PinSHA256) d[@"hy2PinSHA256"] = self.hy2PinSHA256;
    if (self.hy2UpMbps > 0) d[@"hy2UpMbps"] = @(self.hy2UpMbps);
    if (self.hy2DownMbps > 0) d[@"hy2DownMbps"] = @(self.hy2DownMbps);
    if (self.wgPrivateKey) d[@"wgPrivateKey"] = self.wgPrivateKey;
    if (self.wgPeerPublicKey) d[@"wgPeerPublicKey"] = self.wgPeerPublicKey;
    if (self.wgPreSharedKey) d[@"wgPreSharedKey"] = self.wgPreSharedKey;
    if (self.wgAddresses) d[@"wgAddresses"] = self.wgAddresses;
    if (self.wgReserved) d[@"wgReserved"] = self.wgReserved;
    if (self.wgMTU > 0) d[@"wgMTU"] = @(self.wgMTU);
    d[@"tcpPingMs"] = @(self.tcpPingMs);
    d[@"realPingMs"] = @(self.realPingMs);
    return d;
}

+ (nullable instancetype)nodeFromDictionary:(NSDictionary<NSString *, id> *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    LCProxyNode *n = [[LCProxyNode alloc] init];
    if ([dict[@"nodeID"] isKindOfClass:[NSString class]]) n.nodeID = dict[@"nodeID"];
    if ([dict[@"name"] isKindOfClass:[NSString class]]) n.name = dict[@"name"];
    if ([dict[@"subscriptionID"] isKindOfClass:[NSString class]]) n.subscriptionID = dict[@"subscriptionID"];
    if ([dict[@"protocol"] isKindOfClass:[NSString class]]) {
        n.protocol = [LCProxyNode protocolTypeFromString:dict[@"protocol"]];
    }
    if ([dict[@"host"] isKindOfClass:[NSString class]]) n.host = dict[@"host"];
    n.port = (uint16_t)[dict[@"port"] unsignedIntValue];
    if ([dict[@"uuidOrPassword"] isKindOfClass:[NSString class]]) n.uuidOrPassword = dict[@"uuidOrPassword"];
    if ([dict[@"username"] isKindOfClass:[NSString class]]) n.username = dict[@"username"];
    if ([dict[@"method"] isKindOfClass:[NSString class]]) n.method = dict[@"method"];
    if ([dict[@"encryption"] isKindOfClass:[NSString class]]) n.encryption = dict[@"encryption"];
    if ([dict[@"flow"] isKindOfClass:[NSString class]]) n.flow = dict[@"flow"];
    if ([dict[@"network"] isKindOfClass:[NSString class]]) n.network = dict[@"network"];
    if ([dict[@"path"] isKindOfClass:[NSString class]]) n.path = dict[@"path"];
    if ([dict[@"hostHeader"] isKindOfClass:[NSString class]]) n.hostHeader = dict[@"hostHeader"];
    if ([dict[@"xhttpMode"] isKindOfClass:[NSString class]]) n.xhttpMode = dict[@"xhttpMode"];
    if ([dict[@"xhttpExtra"] isKindOfClass:[NSDictionary class]]) n.xhttpExtra = dict[@"xhttpExtra"];
    if ([dict[@"grpcServiceName"] isKindOfClass:[NSString class]]) n.grpcServiceName = dict[@"grpcServiceName"];
    if ([dict[@"grpcAuthority"] isKindOfClass:[NSString class]]) n.grpcAuthority = dict[@"grpcAuthority"];
    n.grpcMultiMode = [dict[@"grpcMultiMode"] boolValue];
    if ([dict[@"security"] isKindOfClass:[NSString class]]) n.security = dict[@"security"];
    if ([dict[@"sni"] isKindOfClass:[NSString class]]) n.sni = dict[@"sni"];
    if ([dict[@"fingerprint"] isKindOfClass:[NSString class]]) n.fingerprint = dict[@"fingerprint"];
    if ([dict[@"alpn"] isKindOfClass:[NSArray class]]) n.alpn = dict[@"alpn"];
    n.allowInsecure = [dict[@"allowInsecure"] boolValue];
    if ([dict[@"realityPublicKey"] isKindOfClass:[NSString class]]) n.realityPublicKey = dict[@"realityPublicKey"];
    if ([dict[@"realityShortId"] isKindOfClass:[NSString class]]) n.realityShortId = dict[@"realityShortId"];
    if ([dict[@"realitySpiderX"] isKindOfClass:[NSString class]]) n.realitySpiderX = dict[@"realitySpiderX"];
    if ([dict[@"hy2Obfs"] isKindOfClass:[NSString class]]) n.hy2Obfs = dict[@"hy2Obfs"];
    if ([dict[@"hy2ObfsPassword"] isKindOfClass:[NSString class]]) n.hy2ObfsPassword = dict[@"hy2ObfsPassword"];
    if ([dict[@"hy2PinSHA256"] isKindOfClass:[NSString class]]) n.hy2PinSHA256 = dict[@"hy2PinSHA256"];
    n.hy2UpMbps = [dict[@"hy2UpMbps"] integerValue];
    n.hy2DownMbps = [dict[@"hy2DownMbps"] integerValue];
    if ([dict[@"wgPrivateKey"] isKindOfClass:[NSString class]]) n.wgPrivateKey = dict[@"wgPrivateKey"];
    if ([dict[@"wgPeerPublicKey"] isKindOfClass:[NSString class]]) n.wgPeerPublicKey = dict[@"wgPeerPublicKey"];
    if ([dict[@"wgPreSharedKey"] isKindOfClass:[NSString class]]) n.wgPreSharedKey = dict[@"wgPreSharedKey"];
    if ([dict[@"wgAddresses"] isKindOfClass:[NSArray class]]) n.wgAddresses = dict[@"wgAddresses"];
    if ([dict[@"wgReserved"] isKindOfClass:[NSArray class]]) n.wgReserved = dict[@"wgReserved"];
    n.wgMTU = [dict[@"wgMTU"] integerValue] ?: 1280;
    n.tcpPingMs = dict[@"tcpPingMs"] ? [dict[@"tcpPingMs"] integerValue] : -1;
    n.realPingMs = dict[@"realPingMs"] ? [dict[@"realPingMs"] integerValue] : -1;

    if (n.protocol == LCProxyProtocolUnknown || n.host.length == 0 || n.port == 0) {
        return nil;
    }
    return n;
}

@end
