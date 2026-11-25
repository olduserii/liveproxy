#import "LCConfigNormalizer.h"
#import "LCProxyHooks.h"

@implementation LCSubscriptionInfo

static NSString *lc_formatBytes(int64_t bytes) {
    if (bytes <= 0) return @"0 B";
    double val = (double)bytes;
    NSArray<NSString *> *units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    NSUInteger idx = 0;
    while (val >= 1024.0 && idx < units.count - 1) {
        val /= 1024.0;
        idx++;
    }
    return [NSString stringWithFormat:@"%.2f %@", val, units[idx]];
}

- (NSString *)formattedUsageSummary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    int64_t used = self.uploadBytes + self.downloadBytes;
    if (self.totalBytes > 0) {
        [parts addObject:[NSString stringWithFormat:@"%@ / %@", lc_formatBytes(used), lc_formatBytes(self.totalBytes)]];
    } else if (used > 0) {
        [parts addObject:[NSString stringWithFormat:@"Used %@", lc_formatBytes(used)]];
    }
    if (self.expireTimestamp > 0) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)self.expireTimestamp];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd";
        [parts addObject:[NSString stringWithFormat:@"до %@", [df stringFromDate:date]]];
    }
    return [parts componentsJoinedByString:@" · "];
}

@end

@implementation LCConfigNormalizer

#pragma mark - Helpers

static NSString *lc_decodeBase64Flexible(NSString *input) {
    if (input.length == 0) return nil;
    NSString *cleaned = [[input componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         componentsJoinedByString:@""];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger rem = cleaned.length % 4;
    if (rem > 0) {
        cleaned = [cleaned stringByPaddingToLength:cleaned.length + (4 - rem) withString:@"=" startingAtIndex:0];
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:cleaned options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (data.length == 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSDictionary<NSString *, NSString *> *lc_queryDictionaryFromURL(NSURLComponents *comps) {
    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in comps.queryItems) {
        if (item.name.length > 0 && item.value != nil) {
            dict[item.name.lowercaseString] = item.value;
        }
    }
    return dict;
}

static NSString *lc_nonEmptyString(id obj) {
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        return s.length > 0 ? s : nil;
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)obj stringValue];
    }
    return nil;
}

static NSString *lc_normalizeNetwork(NSString *rawNet) {
    NSString *n = [[rawNet ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (n.length == 0 || [n isEqualToString:@"tcp"] || [n isEqualToString:@"raw"]) return @"raw";
    if ([n isEqualToString:@"splithttp"] || [n isEqualToString:@"xhttp"]) return @"xhttp";
    if ([n isEqualToString:@"ws"] || [n isEqualToString:@"websocket"]) return @"ws";
    if ([n isEqualToString:@"grpc"]) return @"grpc";
    if ([n isEqualToString:@"httpupgrade"]) return @"httpupgrade";
    return @"raw";
}

#pragma mark - Universal Entry Point

+ (NSArray<LCProxyNode *> *)parseAnyPayload:(NSString *)rawText
                             subscriptionID:(NSString *)subscriptionID
                                      error:(NSError **)error {
    NSString *trimmed = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCConfigNormalizer"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Пустой текст подписки или ключа"}];
        }
        return @[];
    }

    // 1. Try JSON directly (Xray JSON, array of Xray configs, single outbound, or sing-box JSON)
    if ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["]) {
        NSArray<LCProxyNode *> *jsonNodes = [self parseJSONPayload:trimmed subscriptionID:subscriptionID];
        if (jsonNodes.count > 0) {
            return jsonNodes;
        }
    }

    // 2. Try direct URI lines
    NSArray<LCProxyNode *> *directNodes = [self parseURILines:trimmed subscriptionID:subscriptionID];
    if (directNodes.count > 0) {
        return directNodes;
    }

    // 3. Try Base64 decoding (may decode to URI list OR JSON)
    NSString *decoded = lc_decodeBase64Flexible(trimmed);
    if (decoded.length > 0) {
        NSString *decodedTrimmed = [decoded stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([decodedTrimmed hasPrefix:@"{"] || [decodedTrimmed hasPrefix:@"["]) {
            NSArray<LCProxyNode *> *jsonNodes = [self parseJSONPayload:decodedTrimmed subscriptionID:subscriptionID];
            if (jsonNodes.count > 0) return jsonNodes;
        }
        NSArray<LCProxyNode *> *b64Nodes = [self parseURILines:decodedTrimmed subscriptionID:subscriptionID];
        if (b64Nodes.count > 0) return b64Nodes;
    }

    if (error) {
        *error = [NSError errorWithDomain:@"LCConfigNormalizer"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Не удалось распознать поддерживаемые узлы (URI/Base64/JSON)"}];
    }
    return @[];
}

+ (NSArray<LCProxyNode *> *)parseURILines:(NSString *)text subscriptionID:(NSString *)subscriptionID {
    NSMutableArray<LCProxyNode *> *nodes = [NSMutableArray array];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length < 6) continue;
        LCProxyNode *node = [self parseSingleURI:line subscriptionID:subscriptionID];
        if (node) {
            [nodes addObject:node];
        }
    }
    return nodes;
}

#pragma mark - Single URI Parsers

+ (nullable LCProxyNode *)parseSingleURI:(NSString *)uriString subscriptionID:(NSString *)subscriptionID {
    NSString *s = [uriString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = s.lowercaseString;

    if ([lower hasPrefix:@"vless://"]) {
        return [self parseVLESSTrojanURI:s protocol:LCProxyProtocolVLESS subscriptionID:subscriptionID];
    }
    if ([lower hasPrefix:@"trojan://"]) {
        return [self parseVLESSTrojanURI:s protocol:LCProxyProtocolTrojan subscriptionID:subscriptionID];
    }
    if ([lower hasPrefix:@"hysteria2://"] || [lower hasPrefix:@"hy2://"]) {
        return [self parseHysteria2URI:s subscriptionID:subscriptionID];
    }
    if ([lower hasPrefix:@"vmess://"]) {
        return [self parseVMessURI:s subscriptionID:subscriptionID];
    }
    if ([lower hasPrefix:@"ss://"]) {
        return [self parseShadowsocksURI:s subscriptionID:subscriptionID];
    }
    if ([lower hasPrefix:@"wireguard://"] || [lower hasPrefix:@"wg://"]) {
        return [self parseWireGuardURI:s subscriptionID:subscriptionID];
    }
    if ([lower hasPrefix:@"socks://"] || [lower hasPrefix:@"socks5://"]) {
        return [self parseSimpleProxyURI:s protocol:LCProxyProtocolSOCKS5 subscriptionID:subscriptionID];
    }
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) {
        return [self parseSimpleProxyURI:s protocol:LCProxyProtocolHTTP subscriptionID:subscriptionID];
    }
    return nil;
}

+ (nullable LCProxyNode *)parseVLESSTrojanURI:(NSString *)uri
                                     protocol:(LCProxyProtocol)protocol
                               subscriptionID:(NSString *)subscriptionID {
    NSURLComponents *comps = [NSURLComponents componentsWithString:uri];
    if (!comps || comps.host.length == 0 || comps.port.unsignedIntValue == 0) return nil;

    NSDictionary<NSString *, NSString *> *q = lc_queryDictionaryFromURL(comps);
    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = protocol;
    node.subscriptionID = subscriptionID;
    node.host = comps.host;
    node.port = (uint16_t)comps.port.unsignedIntValue;
    node.uuidOrPassword = [comps.user stringByRemovingPercentEncoding] ?: comps.user;
    node.name = comps.fragment.length > 0 ? comps.fragment : [NSString stringWithFormat:@"%@:%u", node.host, node.port];

    if (protocol == LCProxyProtocolVLESS) {
        node.encryption = q[@"encryption"].length > 0 ? q[@"encryption"] : @"none";
        node.flow = q[@"flow"];
    }

    NSString *sec = q[@"security"];
    if (sec.length == 0) {
        sec = (protocol == LCProxyProtocolTrojan) ? @"tls" : @"none";
    }
    node.security = sec.lowercaseString;
    node.sni = q[@"sni"] ?: q[@"peer"];
    node.fingerprint = q[@"fp"] ?: @"chrome";
    if (q[@"alpn"].length > 0) {
        node.alpn = [q[@"alpn"] componentsSeparatedByString:@","];
    }
    node.allowInsecure = ([q[@"allowinsecure"] isEqualToString:@"1"] || [q[@"insecure"] isEqualToString:@"1"] ||
                          [q[@"allowinsecure"].lowercaseString isEqualToString:@"true"]);

    node.realityPublicKey = q[@"pbk"];
    node.realityShortId = q[@"sid"];
    node.realitySpiderX = q[@"spx"];

    node.network = lc_normalizeNetwork(q[@"type"] ?: q[@"net"]);
    node.path = q[@"path"];
    node.hostHeader = q[@"host"];
    if ([node.network isEqualToString:@"xhttp"]) {
        node.xhttpMode = q[@"mode"].length > 0 ? q[@"mode"] : @"auto";
        if (q[@"extra"].length > 0) {
            NSData *extraData = [q[@"extra"] dataUsingEncoding:NSUTF8StringEncoding];
            id extraObj = [NSJSONSerialization JSONObjectWithData:extraData options:0 error:nil];
            if ([extraObj isKindOfClass:[NSDictionary class]]) {
                node.xhttpExtra = extraObj;
            }
        }
    } else if ([node.network isEqualToString:@"grpc"]) {
        node.grpcServiceName = q[@"servicename"] ?: q[@"path"];
        node.grpcAuthority = q[@"authority"] ?: q[@"host"];
        node.grpcMultiMode = [q[@"mode"].lowercaseString isEqualToString:@"multi"];
    }

    return node;
}

+ (nullable LCProxyNode *)parseHysteria2URI:(NSString *)uri subscriptionID:(NSString *)subscriptionID {
    NSString *normalized = uri;
    if ([normalized.lowercaseString hasPrefix:@"hy2://"]) {
        normalized = [@"hysteria2://" stringByAppendingString:[normalized substringFromIndex:6]];
    }
    NSURLComponents *comps = [NSURLComponents componentsWithString:normalized];
    if (!comps || comps.host.length == 0 || comps.port.unsignedIntValue == 0) return nil;

    NSDictionary<NSString *, NSString *> *q = lc_queryDictionaryFromURL(comps);
    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = LCProxyProtocolHysteria2;
    node.subscriptionID = subscriptionID;
    node.host = comps.host;
    node.port = (uint16_t)comps.port.unsignedIntValue;
    if (comps.user.length > 0 && comps.password.length > 0) {
        node.uuidOrPassword = [NSString stringWithFormat:@"%@:%@", comps.user, comps.password];
    } else {
        node.uuidOrPassword = comps.user ?: comps.password;
    }
    node.name = comps.fragment.length > 0 ? comps.fragment : [NSString stringWithFormat:@"HY2 %@:%u", node.host, node.port];
    node.security = @"tls";
    node.sni = q[@"sni"] ?: node.host;
    node.allowInsecure = ([q[@"insecure"] isEqualToString:@"1"] || [q[@"insecure"].lowercaseString isEqualToString:@"true"]);
    node.hy2Obfs = q[@"obfs"];
    node.hy2ObfsPassword = q[@"obfs-password"];
    node.hy2PinSHA256 = q[@"pinsha256"];
    node.hy2UpMbps = q[@"upmbps"].integerValue;
    node.hy2DownMbps = q[@"downmbps"].integerValue;
    return node;
}

+ (nullable LCProxyNode *)parseVMessURI:(NSString *)uri subscriptionID:(NSString *)subscriptionID {
    NSString *b64 = [uri substringFromIndex:8];
    NSString *jsonStr = lc_decodeBase64Flexible(b64);
    if (jsonStr.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:[jsonStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;

    NSString *host = lc_nonEmptyString(d[@"add"]);
    uint16_t port = (uint16_t)[lc_nonEmptyString(d[@"port"]) integerValue];
    NSString *uuid = lc_nonEmptyString(d[@"id"]);
    if (host.length == 0 || port == 0 || uuid.length == 0) return nil;

    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = LCProxyProtocolVMess;
    node.subscriptionID = subscriptionID;
    node.host = host;
    node.port = port;
    node.uuidOrPassword = uuid;
    node.name = lc_nonEmptyString(d[@"ps"]) ?: [NSString stringWithFormat:@"VMess %@:%u", host, port];
    node.method = lc_nonEmptyString(d[@"scy"]) ?: @"auto";
    node.network = lc_normalizeNetwork(lc_nonEmptyString(d[@"net"]));
    node.path = lc_nonEmptyString(d[@"path"]);
    node.hostHeader = lc_nonEmptyString(d[@"host"]);
    NSString *tls = lc_nonEmptyString(d[@"tls"]);
    node.security = [tls.lowercaseString isEqualToString:@"tls"] ? @"tls" : @"none";
    node.sni = lc_nonEmptyString(d[@"sni"]) ?: node.hostHeader;
    node.fingerprint = lc_nonEmptyString(d[@"fp"]) ?: @"chrome";
    if ([node.network isEqualToString:@"grpc"]) {
        node.grpcServiceName = node.path;
    }
    return node;
}

+ (nullable LCProxyNode *)parseShadowsocksURI:(NSString *)uri subscriptionID:(NSString *)subscriptionID {
    // Handles both SIP002 (ss://base64(method:pass)@host:port#tag) and legacy (ss://base64(method:pass@host:port)#tag)
    NSString *body = [uri substringFromIndex:5];
    NSString *tag = nil;
    NSRange hashRange = [body rangeOfString:@"#"];
    if (hashRange.location != NSNotFound) {
        tag = [[body substringFromIndex:hashRange.location + 1] stringByRemovingPercentEncoding];
        body = [body substringToIndex:hashRange.location];
    }
    // Strip plugin query if present
    NSRange qRange = [body rangeOfString:@"?"];
    if (qRange.location != NSNotFound) {
        body = [body substringToIndex:qRange.location];
    }

    NSString *method = nil;
    NSString *password = nil;
    NSString *host = nil;
    uint16_t port = 0;

    NSRange atRange = [body rangeOfString:@"@" options:NSBackwardsSearch];
    if (atRange.location != NSNotFound) {
        NSString *userPart = [body substringToIndex:atRange.location];
        NSString *hostPort = [body substringFromIndex:atRange.location + 1];

        NSString *decodedUser = [userPart containsString:@":"] ? [userPart stringByRemovingPercentEncoding] : lc_decodeBase64Flexible(userPart);
        NSRange colon = [decodedUser rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            method = [decodedUser substringToIndex:colon.location];
            password = [decodedUser substringFromIndex:colon.location + 1];
        }

        NSURLComponents *hc = [NSURLComponents componentsWithString:[@"http://" stringByAppendingString:hostPort]];
        host = hc.host;
        port = (uint16_t)hc.port.unsignedIntValue;
    } else {
        NSString *decoded = lc_decodeBase64Flexible(body);
        NSRange decAt = [decoded rangeOfString:@"@" options:NSBackwardsSearch];
        if (decAt.location != NSNotFound) {
            NSString *userPart = [decoded substringToIndex:decAt.location];
            NSString *hostPort = [decoded substringFromIndex:decAt.location + 1];
            NSRange colon = [userPart rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                method = [userPart substringToIndex:colon.location];
                password = [userPart substringFromIndex:colon.location + 1];
            }
            NSURLComponents *hc = [NSURLComponents componentsWithString:[@"http://" stringByAppendingString:hostPort]];
            host = hc.host;
            port = (uint16_t)hc.port.unsignedIntValue;
        }
    }

    if (host.length == 0 || port == 0 || method.length == 0 || password.length == 0) return nil;

    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = LCProxyProtocolShadowsocks;
    node.subscriptionID = subscriptionID;
    node.host = host;
    node.port = port;
    node.method = method;
    node.uuidOrPassword = password;
    node.name = tag.length > 0 ? tag : [NSString stringWithFormat:@"SS %@:%u", host, port];
    return node;
}

+ (nullable LCProxyNode *)parseWireGuardURI:(NSString *)uri subscriptionID:(NSString *)subscriptionID {
    NSString *normalized = uri;
    if ([normalized.lowercaseString hasPrefix:@"wg://"]) {
        normalized = [@"wireguard://" stringByAppendingString:[normalized substringFromIndex:5]];
    }
    NSURLComponents *comps = [NSURLComponents componentsWithString:normalized];
    if (!comps || comps.host.length == 0 || comps.port.unsignedIntValue == 0) return nil;
    NSDictionary<NSString *, NSString *> *q = lc_queryDictionaryFromURL(comps);

    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = LCProxyProtocolWireGuard;
    node.subscriptionID = subscriptionID;
    node.host = comps.host;
    node.port = (uint16_t)comps.port.unsignedIntValue;
    node.wgPrivateKey = [comps.user stringByRemovingPercentEncoding] ?: comps.user;
    node.wgPeerPublicKey = q[@"publickey"] ?: q[@"pbk"];
    node.wgPreSharedKey = q[@"presharedkey"] ?: q[@"psk"];
    if (q[@"address"].length > 0) {
        node.wgAddresses = [q[@"address"] componentsSeparatedByString:@","];
    } else {
        node.wgAddresses = @[@"10.0.0.2/32"];
    }
    if (q[@"reserved"].length > 0) {
        NSMutableArray<NSNumber *> *res = [NSMutableArray array];
        for (NSString *part in [q[@"reserved"] componentsSeparatedByString:@","]) {
            [res addObject:@(part.integerValue)];
        }
        if (res.count == 3) node.wgReserved = res;
    }
    node.wgMTU = q[@"mtu"].integerValue ?: 1280;
    node.name = comps.fragment.length > 0 ? comps.fragment : [NSString stringWithFormat:@"WG %@:%u", node.host, node.port];
    return node;
}

+ (nullable LCProxyNode *)parseSimpleProxyURI:(NSString *)uri
                                     protocol:(LCProxyProtocol)protocol
                               subscriptionID:(NSString *)subscriptionID {
    NSURLComponents *comps = [NSURLComponents componentsWithString:uri];
    if (!comps || comps.host.length == 0 || comps.port.unsignedIntValue == 0) return nil;
    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = protocol;
    node.subscriptionID = subscriptionID;
    node.host = comps.host;
    node.port = (uint16_t)comps.port.unsignedIntValue;
    node.username = comps.user;
    node.uuidOrPassword = comps.password;
    node.name = comps.fragment.length > 0 ? comps.fragment : [NSString stringWithFormat:@"%@:%u", node.host, node.port];
    return node;
}

#pragma mark - JSON Parsers (Xray JSON & sing-box JSON)

+ (NSArray<LCProxyNode *> *)parseJSONPayload:(NSString *)jsonText subscriptionID:(NSString *)subscriptionID {
    NSData *data = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @[];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!root) return @[];

    NSMutableArray<LCProxyNode *> *result = [NSMutableArray array];
    if ([root isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)root) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                [self extractNodesFromJSONObject:(NSDictionary *)item into:result subscriptionID:subscriptionID];
            }
        }
    } else if ([root isKindOfClass:[NSDictionary class]]) {
        [self extractNodesFromJSONObject:(NSDictionary *)root into:result subscriptionID:subscriptionID];
    }
    return result;
}

+ (void)extractNodesFromJSONObject:(NSDictionary *)obj
                              into:(NSMutableArray<LCProxyNode *> *)outNodes
                    subscriptionID:(NSString *)subscriptionID {
    NSString *remarks = lc_nonEmptyString(obj[@"remarks"]) ?: lc_nonEmptyString(obj[@"ps"]);

    // Full Xray or sing-box config with "outbounds"
    if ([obj[@"outbounds"] isKindOfClass:[NSArray class]]) {
        for (id ob in (NSArray *)obj[@"outbounds"]) {
            if (![ob isKindOfClass:[NSDictionary class]]) continue;
            LCProxyNode *node = [self parseOutboundDictionary:(NSDictionary *)ob
                                                 fallbackName:remarks
                                               subscriptionID:subscriptionID];
            if (node) [outNodes addObject:node];
        }
        return;
    }

    // Single outbound dictionary (either Xray "protocol" or sing-box "type")
    LCProxyNode *single = [self parseOutboundDictionary:obj fallbackName:remarks subscriptionID:subscriptionID];
    if (single) [outNodes addObject:single];
}

+ (nullable LCProxyNode *)parseOutboundDictionary:(NSDictionary *)ob
                                     fallbackName:(nullable NSString *)fallbackName
                                   subscriptionID:(NSString *)subscriptionID {
    // 1. Detect Xray outbound ("protocol") vs sing-box outbound ("type")
    NSString *xrayProto = lc_nonEmptyString(ob[@"protocol"]).lowercaseString;
    NSString *sbType = lc_nonEmptyString(ob[@"type"]).lowercaseString;

    if (xrayProto.length > 0) {
        if ([xrayProto isEqualToString:@"freedom"] || [xrayProto isEqualToString:@"blackhole"] ||
            [xrayProto isEqualToString:@"dns"] || [xrayProto isEqualToString:@"direct"] ||
            [xrayProto isEqualToString:@"block"]) {
            return nil;
        }
        return [self parseXrayOutbound:ob protocolStr:xrayProto fallbackName:fallbackName subscriptionID:subscriptionID];
    }

    if (sbType.length > 0) {
        if ([sbType isEqualToString:@"direct"] || [sbType isEqualToString:@"block"] ||
            [sbType isEqualToString:@"dns"] || [sbType isEqualToString:@"selector"] ||
            [sbType isEqualToString:@"urltest"]) {
            return nil;
        }
        return [self parseSingBoxOutbound:ob typeStr:sbType fallbackName:fallbackName subscriptionID:subscriptionID];
    }

    return nil;
}

+ (nullable LCProxyNode *)parseXrayOutbound:(NSDictionary *)ob
                                protocolStr:(NSString *)protoStr
                               fallbackName:(nullable NSString *)fallbackName
                             subscriptionID:(NSString *)subscriptionID {
    LCProxyProtocol proto = [LCProxyNode protocolTypeFromString:protoStr];
    if (proto == LCProxyProtocolUnknown) return nil;

    NSDictionary *settings = [ob[@"settings"] isKindOfClass:[NSDictionary class]] ? ob[@"settings"] : @{};
    NSDictionary *stream = [ob[@"streamSettings"] isKindOfClass:[NSDictionary class]] ? ob[@"streamSettings"] : @{};

    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = proto;
    node.subscriptionID = subscriptionID;

    NSString *tag = lc_nonEmptyString(ob[@"tag"]);
    node.name = fallbackName.length > 0 ? fallbackName : (tag.length > 0 && ![tag isEqualToString:@"proxy"] ? tag : nil);

    if (proto == LCProxyProtocolVLESS || proto == LCProxyProtocolVMess) {
        NSArray *vnext = [settings[@"vnext"] isKindOfClass:[NSArray class]] ? settings[@"vnext"] : nil;
        NSDictionary *srv = [vnext.firstObject isKindOfClass:[NSDictionary class]] ? vnext.firstObject : nil;
        if (!srv) return nil;
        node.host = lc_nonEmptyString(srv[@"address"]);
        node.port = (uint16_t)[srv[@"port"] unsignedIntValue];
        NSArray *users = [srv[@"users"] isKindOfClass:[NSArray class]] ? srv[@"users"] : nil;
        NSDictionary *user = [users.firstObject isKindOfClass:[NSDictionary class]] ? users.firstObject : nil;
        node.uuidOrPassword = lc_nonEmptyString(user[@"id"]);
        if (proto == LCProxyProtocolVLESS) {
            node.encryption = lc_nonEmptyString(user[@"encryption"]) ?: @"none";
            node.flow = lc_nonEmptyString(user[@"flow"]);
        } else {
            node.method = lc_nonEmptyString(user[@"security"]) ?: @"auto";
        }
    } else if (proto == LCProxyProtocolTrojan || proto == LCProxyProtocolShadowsocks ||
               proto == LCProxyProtocolSOCKS5 || proto == LCProxyProtocolHTTP) {
        NSArray *servers = [settings[@"servers"] isKindOfClass:[NSArray class]] ? settings[@"servers"] : nil;
        NSDictionary *srv = [servers.firstObject isKindOfClass:[NSDictionary class]] ? servers.firstObject : nil;
        if (!srv) return nil;
        node.host = lc_nonEmptyString(srv[@"address"]);
        node.port = (uint16_t)[srv[@"port"] unsignedIntValue];
        if (proto == LCProxyProtocolTrojan) {
            node.uuidOrPassword = lc_nonEmptyString(srv[@"password"]);
        } else if (proto == LCProxyProtocolShadowsocks) {
            node.method = lc_nonEmptyString(srv[@"method"]);
            node.uuidOrPassword = lc_nonEmptyString(srv[@"password"]);
        } else {
            NSArray *users = [srv[@"users"] isKindOfClass:[NSArray class]] ? srv[@"users"] : nil;
            NSDictionary *u = [users.firstObject isKindOfClass:[NSDictionary class]] ? users.firstObject : nil;
            node.username = lc_nonEmptyString(u[@"user"]);
            node.uuidOrPassword = lc_nonEmptyString(u[@"pass"]);
        }
    } else if (proto == LCProxyProtocolHysteria2) {
        node.host = lc_nonEmptyString(settings[@"address"]) ?: lc_nonEmptyString(settings[@"server"]);
        node.port = (uint16_t)[settings[@"port"] unsignedIntValue];
        node.uuidOrPassword = lc_nonEmptyString(settings[@"password"]) ?: lc_nonEmptyString(settings[@"auth"]);
        NSDictionary *obfs = [settings[@"obfs"] isKindOfClass:[NSDictionary class]] ? settings[@"obfs"] : nil;
        node.hy2Obfs = lc_nonEmptyString(obfs[@"type"]);
        node.hy2ObfsPassword = lc_nonEmptyString(obfs[@"password"]);
    } else if (proto == LCProxyProtocolWireGuard) {
        node.wgPrivateKey = lc_nonEmptyString(settings[@"secretKey"]);
        if ([settings[@"address"] isKindOfClass:[NSArray class]]) node.wgAddresses = settings[@"address"];
        if ([settings[@"reserved"] isKindOfClass:[NSArray class]]) node.wgReserved = settings[@"reserved"];
        node.wgMTU = [settings[@"mtu"] integerValue] ?: 1280;
        NSArray *peers = [settings[@"peers"] isKindOfClass:[NSArray class]] ? settings[@"peers"] : nil;
        NSDictionary *peer = [peers.firstObject isKindOfClass:[NSDictionary class]] ? peers.firstObject : nil;
        node.wgPeerPublicKey = lc_nonEmptyString(peer[@"publicKey"]);
        node.wgPreSharedKey = lc_nonEmptyString(peer[@"preSharedKey"]);
        NSString *endpoint = lc_nonEmptyString(peer[@"endpoint"]);
        if (endpoint.length > 0) {
            NSURLComponents *ec = [NSURLComponents componentsWithString:[@"http://" stringByAppendingString:endpoint]];
            node.host = ec.host;
            node.port = (uint16_t)ec.port.unsignedIntValue;
        }
    }

    if (node.host.length == 0 || node.port == 0) return nil;
    if (node.name.length == 0) {
        node.name = [NSString stringWithFormat:@"%@ %@:%u", [LCProxyNode protocolNameForType:proto].uppercaseString, node.host, node.port];
    }

    // Stream settings normalization
    node.network = lc_normalizeNetwork(lc_nonEmptyString(stream[@"network"]));
    NSString *sec = lc_nonEmptyString(stream[@"security"]).lowercaseString;
    node.security = sec.length > 0 ? sec : @"none";

    NSDictionary *tls = [stream[@"tlsSettings"] isKindOfClass:[NSDictionary class]] ? stream[@"tlsSettings"] : nil;
    NSDictionary *reality = [stream[@"realitySettings"] isKindOfClass:[NSDictionary class]] ? stream[@"realitySettings"] : nil;
    if ([node.security isEqualToString:@"reality"] && reality) {
        node.sni = lc_nonEmptyString(reality[@"serverName"]);
        node.fingerprint = lc_nonEmptyString(reality[@"fingerprint"]) ?: @"chrome";
        node.realityPublicKey = lc_nonEmptyString(reality[@"publicKey"]) ?: lc_nonEmptyString(reality[@"password"]);
        node.realityShortId = lc_nonEmptyString(reality[@"shortId"]);
        node.realitySpiderX = lc_nonEmptyString(reality[@"spiderX"]);
    } else if (tls) {
        node.sni = lc_nonEmptyString(tls[@"serverName"]);
        node.fingerprint = lc_nonEmptyString(tls[@"fingerprint"]) ?: @"chrome";
        if ([tls[@"alpn"] isKindOfClass:[NSArray class]]) node.alpn = tls[@"alpn"];
        node.allowInsecure = [tls[@"allowInsecure"] boolValue];
    }

    NSDictionary *xhttp = [stream[@"xhttpSettings"] isKindOfClass:[NSDictionary class]] ? stream[@"xhttpSettings"]
                        : ([stream[@"splithttpSettings"] isKindOfClass:[NSDictionary class]] ? stream[@"splithttpSettings"] : nil);
    if ([node.network isEqualToString:@"xhttp"] && xhttp) {
        node.path = lc_nonEmptyString(xhttp[@"path"]) ?: @"/";
        node.hostHeader = lc_nonEmptyString(xhttp[@"host"]);
        node.xhttpMode = lc_nonEmptyString(xhttp[@"mode"]) ?: @"auto";
        if ([xhttp[@"extra"] isKindOfClass:[NSDictionary class]]) node.xhttpExtra = xhttp[@"extra"];
    } else if ([node.network isEqualToString:@"ws"]) {
        NSDictionary *ws = [stream[@"wsSettings"] isKindOfClass:[NSDictionary class]] ? stream[@"wsSettings"] : nil;
        node.path = lc_nonEmptyString(ws[@"path"]) ?: @"/";
        NSDictionary *hdrs = [ws[@"headers"] isKindOfClass:[NSDictionary class]] ? ws[@"headers"] : nil;
        node.hostHeader = lc_nonEmptyString(ws[@"host"]) ?: lc_nonEmptyString(hdrs[@"Host"]);
    } else if ([node.network isEqualToString:@"httpupgrade"]) {
        NSDictionary *hu = [stream[@"httpupgradeSettings"] isKindOfClass:[NSDictionary class]] ? stream[@"httpupgradeSettings"] : nil;
        node.path = lc_nonEmptyString(hu[@"path"]) ?: @"/";
        node.hostHeader = lc_nonEmptyString(hu[@"host"]);
    } else if ([node.network isEqualToString:@"grpc"]) {
        NSDictionary *gr = [stream[@"grpcSettings"] isKindOfClass:[NSDictionary class]] ? stream[@"grpcSettings"] : nil;
        node.grpcServiceName = lc_nonEmptyString(gr[@"serviceName"]);
        node.grpcAuthority = lc_nonEmptyString(gr[@"authority"]);
        node.grpcMultiMode = [gr[@"multiMode"] boolValue];
    }

    return node;
}

+ (nullable LCProxyNode *)parseSingBoxOutbound:(NSDictionary *)ob
                                       typeStr:(NSString *)typeStr
                                  fallbackName:(nullable NSString *)fallbackName
                                subscriptionID:(NSString *)subscriptionID {
    LCProxyProtocol proto = [LCProxyNode protocolTypeFromString:typeStr];
    if (proto == LCProxyProtocolUnknown) return nil;

    NSString *host = lc_nonEmptyString(ob[@"server"]);
    uint16_t port = (uint16_t)[ob[@"server_port"] unsignedIntValue];
    if (host.length == 0 || port == 0) return nil;

    LCProxyNode *node = [[LCProxyNode alloc] init];
    node.protocol = proto;
    node.subscriptionID = subscriptionID;
    node.host = host;
    node.port = port;
    NSString *tag = lc_nonEmptyString(ob[@"tag"]);
    node.name = tag.length > 0 ? tag : (fallbackName.length > 0 ? fallbackName : [NSString stringWithFormat:@"%@:%u", host, port]);

    if (proto == LCProxyProtocolVLESS || proto == LCProxyProtocolVMess) {
        node.uuidOrPassword = lc_nonEmptyString(ob[@"uuid"]);
        node.flow = lc_nonEmptyString(ob[@"flow"]);
        node.method = lc_nonEmptyString(ob[@"security"]) ?: @"auto";
    } else if (proto == LCProxyProtocolTrojan || proto == LCProxyProtocolHysteria2) {
        node.uuidOrPassword = lc_nonEmptyString(ob[@"password"]);
        NSDictionary *obfs = [ob[@"obfs"] isKindOfClass:[NSDictionary class]] ? ob[@"obfs"] : nil;
        node.hy2Obfs = lc_nonEmptyString(obfs[@"type"]);
        node.hy2ObfsPassword = lc_nonEmptyString(obfs[@"password"]);
        node.hy2UpMbps = [ob[@"up_mbps"] integerValue];
        node.hy2DownMbps = [ob[@"down_mbps"] integerValue];
    } else if (proto == LCProxyProtocolShadowsocks) {
        node.method = lc_nonEmptyString(ob[@"method"]);
        node.uuidOrPassword = lc_nonEmptyString(ob[@"password"]);
    } else if (proto == LCProxyProtocolWireGuard) {
        node.wgPrivateKey = lc_nonEmptyString(ob[@"private_key"]);
        node.wgPeerPublicKey = lc_nonEmptyString(ob[@"peer_public_key"]);
        node.wgPreSharedKey = lc_nonEmptyString(ob[@"pre_shared_key"]);
        if ([ob[@"local_address"] isKindOfClass:[NSArray class]]) node.wgAddresses = ob[@"local_address"];
        if ([ob[@"reserved"] isKindOfClass:[NSArray class]]) node.wgReserved = ob[@"reserved"];
        node.wgMTU = [ob[@"mtu"] integerValue] ?: 1280;
    } else {
        node.username = lc_nonEmptyString(ob[@"username"]);
        node.uuidOrPassword = lc_nonEmptyString(ob[@"password"]);
    }

    NSDictionary *tls = [ob[@"tls"] isKindOfClass:[NSDictionary class]] ? ob[@"tls"] : nil;
    if ([tls[@"enabled"] boolValue]) {
        NSDictionary *reality = [tls[@"reality"] isKindOfClass:[NSDictionary class]] ? tls[@"reality"] : nil;
        if ([reality[@"enabled"] boolValue]) {
            node.security = @"reality";
            node.realityPublicKey = lc_nonEmptyString(reality[@"public_key"]);
            node.realityShortId = lc_nonEmptyString(reality[@"short_id"]);
        } else {
            node.security = @"tls";
        }
        node.sni = lc_nonEmptyString(tls[@"server_name"]);
        node.allowInsecure = [tls[@"insecure"] boolValue];
        if ([tls[@"alpn"] isKindOfClass:[NSArray class]]) node.alpn = tls[@"alpn"];
        NSDictionary *utls = [tls[@"utls"] isKindOfClass:[NSDictionary class]] ? tls[@"utls"] : nil;
        node.fingerprint = lc_nonEmptyString(utls[@"fingerprint"]) ?: @"chrome";
    }

    NSDictionary *tr = [ob[@"transport"] isKindOfClass:[NSDictionary class]] ? ob[@"transport"] : nil;
    if (tr) {
        node.network = lc_normalizeNetwork(lc_nonEmptyString(tr[@"type"]));
        node.path = lc_nonEmptyString(tr[@"path"]);
        NSDictionary *hdrs = [tr[@"headers"] isKindOfClass:[NSDictionary class]] ? tr[@"headers"] : nil;
        node.hostHeader = lc_nonEmptyString(tr[@"host"]) ?: lc_nonEmptyString(hdrs[@"Host"]);
        node.grpcServiceName = lc_nonEmptyString(tr[@"service_name"]);
    }
    return node;
}

#pragma mark - Subscription HTTP Fetcher (Direct / Loop-Safe)

+ (nullable LCSubscriptionInfo *)parseSubscriptionUserInfoHeader:(nullable NSString *)headerValue {
    if (headerValue.length == 0) return nil;
    LCSubscriptionInfo *info = [[LCSubscriptionInfo alloc] init];
    BOOL foundAny = NO;
    for (NSString *part in [headerValue componentsSeparatedByString:@";"]) {
        NSArray<NSString *> *kv = [part componentsSeparatedByString:@"="];
        if (kv.count != 2) continue;
        NSString *k = [[kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        int64_t v = [[kv[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] longLongValue];
        if ([k isEqualToString:@"upload"]) { info.uploadBytes = v; foundAny = YES; }
        else if ([k isEqualToString:@"download"]) { info.downloadBytes = v; foundAny = YES; }
        else if ([k isEqualToString:@"total"]) { info.totalBytes = v; foundAny = YES; }
        else if ([k isEqualToString:@"expire"]) { info.expireTimestamp = v; foundAny = YES; }
    }
    return foundAny ? info : nil;
}

+ (void)fetchSubscriptionFromURL:(NSString *)urlString
                  subscriptionID:(NSString *)subscriptionID
                      completion:(void (^)(NSArray<LCProxyNode *> *, LCSubscriptionInfo *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:[urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    if (!url) {
        if (completion) {
            completion(nil, nil, [NSError errorWithDomain:@"LCConfigNormalizer"
                                                     code:10
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Некорректный URL подписки"}]);
        }
        return;
    }

    // Use a direct bypassed NSURLSessionConfiguration so subscription updates work even if local proxy is down
    NSURLSessionConfiguration *cfg = LCProxyCreateDirectSessionConfiguration();
    cfg.timeoutIntervalForRequest = 15.0;
    cfg.timeoutIntervalForResource = 25.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"v2rayN/7.10 (LCProxy-XrayRust/1.0)" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        if (error || data.length == 0) {
            if (completion) {
                completion(nil, nil, error ?: [NSError errorWithDomain:@"LCConfigNormalizer"
                                                                  code:11
                                                              userInfo:@{NSLocalizedDescriptionKey: @"Пустой ответ от сервера подписки"}]);
            }
            return;
        }

        NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        LCSubscriptionInfo *info = nil;
        if (httpResp) {
            for (NSString *key in httpResp.allHeaderFields) {
                if ([key.lowercaseString isEqualToString:@"subscription-userinfo"]) {
                    info = [self parseSubscriptionUserInfoHeader:httpResp.allHeaderFields[key]];
                } else if ([key.lowercaseString isEqualToString:@"profile-title"]) {
                    NSString *rawTitle = httpResp.allHeaderFields[key];
                    if (!info) info = [[LCSubscriptionInfo alloc] init];
                    if ([rawTitle hasPrefix:@"base64:"]) {
                        info.profileTitle = lc_decodeBase64Flexible([rawTitle substringFromIndex:7]) ?: rawTitle;
                    } else {
                        info.profileTitle = rawTitle;
                    }
                }
            }
        }

        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!body) body = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        NSError *parseErr = nil;
        NSArray<LCProxyNode *> *nodes = [self parseAnyPayload:body ?: @"" subscriptionID:subscriptionID error:&parseErr];
        if (completion) {
            completion(nodes.count > 0 ? nodes : nil, info, nodes.count > 0 ? nil : parseErr);
        }
    }];
    [task resume];
}

#pragma mark - Strict Minimal Xray-Rust JSON Generator

+ (nullable NSString *)buildStrictXrayJSONForNode:(LCProxyNode *)node
                                        socksPort:(uint16_t)socksPort
                                         httpPort:(uint16_t)httpPort
                                            error:(NSError **)error {
    if (!node || node.host.length == 0 || node.port == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCConfigNormalizer"
                                         code:20
                                     userInfo:@{NSLocalizedDescriptionKey: @"Узел не содержит адрес или порт"}];
        }
        return nil;
    }

    NSDictionary *activeOutbound = [self buildStrictOutboundForNode:node];
    if (!activeOutbound) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCConfigNormalizer"
                                         code:21
                                     userInfo:@{NSLocalizedDescriptionKey: @"Неподдерживаемый протокол для xray-rust"}];
        }
        return nil;
    }

    // Minimal, strictly valid xray-rust config:
    // ONLY log + local loopback inbounds (socks + http) + [activeOutbound, direct].
    // NO observatory, NO fakedns, NO stats, NO policy, NO extraneous provider keys.
    NSDictionary *config = @{
        @"log": @{
            @"loglevel": @"warning"
        },
        @"inbounds": @[
            @{
                @"tag": @"socks-in",
                @"listen": @"127.0.0.1",
                @"port": @(socksPort),
                @"protocol": @"socks",
                @"settings": @{
                    @"udp": @YES
                }
            },
            @{
                @"tag": @"http-in",
                @"listen": @"127.0.0.1",
                @"port": @(httpPort),
                @"protocol": @"http",
                @"settings": @{}
            }
        ],
        @"outbounds": @[
            activeOutbound,
            @{
                @"tag": @"direct",
                @"protocol": @"freedom"
            }
        ]
    };

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:0 error:error];
    if (!jsonData) return nil;
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

+ (nullable NSDictionary<NSString *, id> *)buildStrictOutboundForNode:(LCProxyNode *)node {
    NSMutableDictionary *ob = [NSMutableDictionary dictionary];
    ob[@"tag"] = @"proxy";

    switch (node.protocol) {
        case LCProxyProtocolVLESS: {
            ob[@"protocol"] = @"vless";
            NSMutableDictionary *user = [NSMutableDictionary dictionary];
            user[@"id"] = node.uuidOrPassword ?: @"";
            user[@"encryption"] = node.encryption.length > 0 ? node.encryption : @"none";
            if (node.flow.length > 0) user[@"flow"] = node.flow;

            ob[@"settings"] = @{
                @"vnext": @[
                    @{
                        @"address": node.host,
                        @"port": @(node.port),
                        @"users": @[user]
                    }
                ]
            };
            ob[@"streamSettings"] = [self buildStrictStreamSettingsForNode:node];
            return ob;
        }
        case LCProxyProtocolTrojan: {
            ob[@"protocol"] = @"trojan";
            ob[@"settings"] = @{
                @"servers": @[
                    @{
                        @"address": node.host,
                        @"port": @(node.port),
                        @"password": node.uuidOrPassword ?: @""
                    }
                ]
            };
            ob[@"streamSettings"] = [self buildStrictStreamSettingsForNode:node];
            return ob;
        }
        case LCProxyProtocolVMess: {
            ob[@"protocol"] = @"vmess";
            ob[@"settings"] = @{
                @"vnext": @[
                    @{
                        @"address": node.host,
                        @"port": @(node.port),
                        @"users": @[
                            @{
                                @"id": node.uuidOrPassword ?: @"",
                                @"security": node.method.length > 0 ? node.method : @"auto"
                            }
                        ]
                    }
                ]
            };
            ob[@"streamSettings"] = [self buildStrictStreamSettingsForNode:node];
            return ob;
        }
        case LCProxyProtocolShadowsocks: {
            ob[@"protocol"] = @"shadowsocks";
            ob[@"settings"] = @{
                @"servers": @[
                    @{
                        @"address": node.host,
                        @"port": @(node.port),
                        @"method": node.method.length > 0 ? node.method : @"aes-256-gcm",
                        @"password": node.uuidOrPassword ?: @""
                    }
                ]
            };
            return ob;
        }
        case LCProxyProtocolHysteria2: {
            ob[@"protocol"] = @"hysteria2";
            NSMutableDictionary *settings = [NSMutableDictionary dictionary];
            settings[@"address"] = node.host;
            settings[@"port"] = @(node.port);
            settings[@"password"] = node.uuidOrPassword ?: @"";
            if (node.hy2Obfs.length > 0 && node.hy2ObfsPassword.length > 0) {
                settings[@"obfs"] = @{
                    @"type": node.hy2Obfs,
                    @"password": node.hy2ObfsPassword
                };
            }
            if (node.hy2UpMbps > 0) settings[@"upMbps"] = @(node.hy2UpMbps);
            if (node.hy2DownMbps > 0) settings[@"downMbps"] = @(node.hy2DownMbps);
            ob[@"settings"] = settings;

            NSMutableDictionary *tls = [NSMutableDictionary dictionary];
            if (node.sni.length > 0) tls[@"serverName"] = node.sni;
            if (node.allowInsecure) tls[@"allowInsecure"] = @YES;
            if (node.hy2PinSHA256.length > 0) tls[@"pinnedPeerCertificateChainSha256"] = @[node.hy2PinSHA256];
            ob[@"streamSettings"] = @{
                @"security": @"tls",
                @"tlsSettings": tls
            };
            return ob;
        }
        case LCProxyProtocolWireGuard: {
            ob[@"protocol"] = @"wireguard";
            NSMutableDictionary *peer = [NSMutableDictionary dictionary];
            peer[@"endpoint"] = [NSString stringWithFormat:@"%@:%u", node.host, node.port];
            if (node.wgPeerPublicKey.length > 0) peer[@"publicKey"] = node.wgPeerPublicKey;
            if (node.wgPreSharedKey.length > 0) peer[@"preSharedKey"] = node.wgPreSharedKey;

            NSMutableDictionary *settings = [NSMutableDictionary dictionary];
            settings[@"secretKey"] = node.wgPrivateKey ?: @"";
            settings[@"address"] = node.wgAddresses.count > 0 ? node.wgAddresses : @[@"10.0.0.2/32"];
            settings[@"mtu"] = @(node.wgMTU > 0 ? node.wgMTU : 1280);
            if (node.wgReserved.count == 3) settings[@"reserved"] = node.wgReserved;
            settings[@"peers"] = @[peer];
            ob[@"settings"] = settings;
            return ob;
        }
        case LCProxyProtocolSOCKS5: {
            ob[@"protocol"] = @"socks";
            NSMutableDictionary *srv = [@{ @"address": node.host, @"port": @(node.port) } mutableCopy];
            if (node.username.length > 0 || node.uuidOrPassword.length > 0) {
                srv[@"users"] = @[@{ @"user": node.username ?: @"", @"pass": node.uuidOrPassword ?: @"" }];
            }
            ob[@"settings"] = @{ @"servers": @[srv] };
            return ob;
        }
        case LCProxyProtocolHTTP: {
            ob[@"protocol"] = @"http";
            NSMutableDictionary *srv = [@{ @"address": node.host, @"port": @(node.port) } mutableCopy];
            if (node.username.length > 0 || node.uuidOrPassword.length > 0) {
                srv[@"users"] = @[@{ @"user": node.username ?: @"", @"pass": node.uuidOrPassword ?: @"" }];
            }
            ob[@"settings"] = @{ @"servers": @[srv] };
            return ob;
        }
        default:
            return nil;
    }
}

+ (NSDictionary<NSString *, id> *)buildStrictStreamSettingsForNode:(LCProxyNode *)node {
    NSMutableDictionary *stream = [NSMutableDictionary dictionary];
    NSString *net = lc_normalizeNetwork(node.network);
    stream[@"network"] = net;

    NSString *sec = node.security.length > 0 ? node.security.lowercaseString : @"none";
    stream[@"security"] = sec;

    if ([sec isEqualToString:@"reality"]) {
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        if (node.sni.length > 0) r[@"serverName"] = node.sni;
        r[@"fingerprint"] = node.fingerprint.length > 0 ? node.fingerprint : @"chrome";
        if (node.realityPublicKey.length > 0) r[@"publicKey"] = node.realityPublicKey;
        r[@"shortId"] = node.realityShortId ?: @"";
        if (node.realitySpiderX.length > 0) r[@"spiderX"] = node.realitySpiderX;
        stream[@"realitySettings"] = r;
    } else if ([sec isEqualToString:@"tls"]) {
        NSMutableDictionary *t = [NSMutableDictionary dictionary];
        if (node.sni.length > 0) t[@"serverName"] = node.sni;
        if (node.fingerprint.length > 0) t[@"fingerprint"] = node.fingerprint;
        if (node.alpn.count > 0) t[@"alpn"] = node.alpn;
        if (node.allowInsecure) t[@"allowInsecure"] = @YES;
        stream[@"tlsSettings"] = t;
    }

    if ([net isEqualToString:@"xhttp"]) {
        NSMutableDictionary *x = [NSMutableDictionary dictionary];
        x[@"path"] = node.path.length > 0 ? node.path : @"/";
        if (node.hostHeader.length > 0) x[@"host"] = node.hostHeader;
        x[@"mode"] = node.xhttpMode.length > 0 ? node.xhttpMode : @"auto";
        if (node.xhttpExtra.count > 0) x[@"extra"] = node.xhttpExtra;
        stream[@"xhttpSettings"] = x;
    } else if ([net isEqualToString:@"ws"]) {
        NSMutableDictionary *ws = [NSMutableDictionary dictionary];
        ws[@"path"] = node.path.length > 0 ? node.path : @"/";
        if (node.hostHeader.length > 0) {
            ws[@"headers"] = @{ @"Host": node.hostHeader };
        }
        stream[@"wsSettings"] = ws;
    } else if ([net isEqualToString:@"httpupgrade"]) {
        NSMutableDictionary *hu = [NSMutableDictionary dictionary];
        hu[@"path"] = node.path.length > 0 ? node.path : @"/";
        if (node.hostHeader.length > 0) hu[@"host"] = node.hostHeader;
        stream[@"httpupgradeSettings"] = hu;
    } else if ([net isEqualToString:@"grpc"]) {
        NSMutableDictionary *gr = [NSMutableDictionary dictionary];
        gr[@"serviceName"] = node.grpcServiceName ?: @"";
        if (node.grpcAuthority.length > 0) gr[@"authority"] = node.grpcAuthority;
        if (node.grpcMultiMode) gr[@"multiMode"] = @YES;
        stream[@"grpcSettings"] = gr;
    }

    return stream;
}

@end
