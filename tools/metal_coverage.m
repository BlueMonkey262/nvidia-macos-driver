// Metal API coverage dump (read-only). Creates the default Metal device, then for every MTL* protocol lists its
// methods and for every NVMTL* class the selectors it answers. Prints JSON on stdout; feed it to metal_coverage.py.
// Build and run on the macOS machine with the driver installed:
//   clang -fobjc-arc -framework Foundation -framework Metal -o metal_coverage metal_coverage.m && ./metal_coverage > dump.json
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

static void collect(Protocol *p, NSMutableSet *seen, NSMutableArray *out) {
    NSString *pn = NSStringFromProtocol(p);
    if ([seen containsObject:pn] || [pn isEqualToString:@"NSObject"]) return;
    [seen addObject:pn];
    for (int req = 1; req >= 0; req--)
        for (int inst = 1; inst >= 0; inst--) {
            unsigned n; struct objc_method_description *d = protocol_copyMethodDescriptionList(p, req, inst, &n);
            for (unsigned i = 0; i < n; i++)
                [out addObject:@{@"proto": pn, @"sel": NSStringFromSelector(d[i].name), @"req": @(req), @"inst": @(inst)}];
            free(d);
        }
    unsigned pc; Protocol *__unsafe_unretained *ps = protocol_copyProtocolList(p, &pc);
    for (unsigned i = 0; i < pc; i++) collect(ps[i], seen, out);
    free(ps);
}

int main(void) {
    @autoreleasepool {
        id dev = MTLCreateSystemDefaultDevice();
        NSMutableDictionary *root = [NSMutableDictionary new];
        root[@"device"] = dev ? [dev name] : @"none";
        root[@"deviceClass"] = dev ? NSStringFromClass([dev class]) : @"none";
        unsigned pc; Protocol *__unsafe_unretained *plist = objc_copyProtocolList(&pc);
        NSMutableDictionary *protos = [NSMutableDictionary new];
        for (unsigned i = 0; i < pc; i++) {
            NSString *n = NSStringFromProtocol(plist[i]);
            if (![n hasPrefix:@"MTL"]) continue;
            NSMutableArray *ms = [NSMutableArray new];
            collect(plist[i], [NSMutableSet new], ms);
            protos[n] = ms;
        }
        free(plist);
        root[@"protocols"] = protos;
        unsigned cc; Class *clist = objc_copyClassList(&cc);
        NSMutableDictionary *classes = [NSMutableDictionary new];
        for (unsigned i = 0; i < cc; i++) {
            NSString *cn = NSStringFromClass(clist[i]);
            if (![cn hasPrefix:@"NVMTL"]) continue;
            NSMutableArray *conf = [NSMutableArray new];
            for (NSString *pn in protos)
                if (class_conformsToProtocol(clist[i], NSProtocolFromString(pn))) [conf addObject:pn];
            NSMutableArray *own = [NSMutableArray new];
            unsigned mc; Method *ml = class_copyMethodList(clist[i], &mc);
            for (unsigned j = 0; j < mc; j++) [own addObject:NSStringFromSelector(method_getName(ml[j]))];
            free(ml);
            // inherited-from-superclass methods count as implemented too, so also record the full responds set
            NSMutableArray *resp = [NSMutableArray new];
            for (NSString *pn in conf)
                for (NSDictionary *m in protos[pn]) {
                    SEL s = NSSelectorFromString(m[@"sel"]);
                    BOOL r = [m[@"inst"] boolValue] ? [clist[i] instancesRespondToSelector:s] : [clist[i] respondsToSelector:s];
                    if (r) [resp addObject:[NSString stringWithFormat:@"%@|%@", m[@"inst"], m[@"sel"]]];
                }
            classes[cn] = @{@"conforms": conf, @"own": own, @"responds": resp, @"super": NSStringFromClass(class_getSuperclass(clist[i])) ?: @""};
        }
        free(clist);
        root[@"classes"] = classes;
        NSData *j = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(j.bytes, 1, j.length, stdout);
    }
    return 0;
}
