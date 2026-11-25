#include <metal_stdlib>
using namespace metal;
float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}
float boxhit(float3 ro, float3 rd, float3 center, float3 ext) {
    float3 inv = 1. / (rd + sign(rd) * .00001 + 1e-7);
    float3 a = (center - ext - ro) * inv, b = (center + ext - ro) * inv;
    float3 lo = min(a, b), hi = max(a, b);
    float n = max(max(lo.x, lo.y), lo.z), f = min(min(hi.x, hi.y), hi.z);
    return f >= max(n, .01) ? max(n, .01) : 1e5;
}
float3 scene(float2 uv, float t) {
    float2 p = uv * 2 - 1;
    p.x *= 1.7778;
    float z = t * 8.;
    float3 ro = float3(1.2 * sin(t * .38), 2.7, z), rd = normalize(float3(p.x, -p.y - .16, 1.6));
    float3 col = mix(float3(.45, .61, .83), float3(.13, .28, .56), clamp(rd.y * 2., 0., 1.));
    float best = 1e5;
    float hit = -ro.y / rd.y;
    if (hit > 0) {
        best = hit;
        float3 w = ro + rd * hit;
        float x = abs(w.x);
        float n = hash(floor(w.xz * 17));
        col = x < 4. ? float3(.12, .13, .15) + n * .10 : float3(.08, .20, .075) + n * .16;
        if (abs(x - 3.8) < .08 || abs(w.x) < .045 && fract(w.z * .22) > .35)
            col = float3(.89, .85, .66);
        if (x > 4. && x < 4.4)
            col = mix(float3(.7), float3(.72, .07, .03), step(.5, fract(w.z)));
    }
    for (int i = 0; i < 20; i++) {
        float zz = floor(z / 12.) * 12. + float(i - 1) * 12.;
        for (int j = 0; j < 2; j++) {
            float side = j ? 1. : -1.;
            float seed = hash(float2(zz, side));
            float h = 3. + seed * 9.;
            float3 c = float3(side * (7. + seed * 2.), h * .5, zz);
            float3 e = float3(2.2, h * .5, 4.);
            float v = boxhit(ro, rd, c, e);
            if (v < best) {
                best = v;
                float3 w = ro + rd * v;
                float3 q = abs((w - c) / e);
                float u = q.x > q.z ? w.z : w.x;
                float2 win = fract(float2(u * .8, w.y * .8));
                float k = step(.18, win.x) * step(win.x, .78) * step(.22, win.y) * step(win.y, .73);
                float shade = q.x > q.z ? .72 : 1.;
                col = (float3(.18, .24, .31) + seed * .20 + k * float3(.42, .33, .14)) * shade;
            }
        }
    }
    for (int i = 0; i < 6; i++) {
        float d = 8. + float(i) * 10. + 3. * sin(t * .75 + i);
        float3 c = float3(2. * sin(t * .7 + i * 2.4), .65, z + d);
        float v = boxhit(ro, rd, c, float3(.9, .65, 1.7));
        if (v < best) {
            best = v;
            float3 w = ro + rd * v;
            float3 q = w - c;
            col = float3(.14 + .5 * hash(float2(i, 2)), .08 + .35 * hash(float2(i, 4)), .13);
            if (q.y > .25)
                col = float3(.11, .22, .31);
            if (q.z < -1.6 && abs(q.x) > .5 && q.y < .15)
                col = float3(.98, .06, .02);
        }
    }
    float fog = 1. - exp(-best * .012);
    col = mix(col, float3(.55, .66, .75), min(fog, .87));
    float2 hud = uv - float2(.87, .86);
    if (abs(length(hud) - .07) < .003 || abs(hud.y) < .002 && abs(hud.x) < .045)
        col = float3(.9);
    return clamp(col, 0., 1.);
}
float3 yuv(float3 c) {
    return float3((16. + 219. * dot(c, float3(.2126, .7152, .0722))) / 255.,
                  (128. + 224. * dot(c, float3(-.1146, -.3854, .5))) / 255.,
                  (128. + 224. * dot(c, float3(.5, -.4542, -.0458))) / 255.);
}
kernel void generate(texture2d<float, access::write> y [[texture(0)]],
                     texture2d<float, access::write> uv [[texture(1)]],
                     constant float &t [[buffer(0)]],
                     uint2 g [[thread_position_in_grid]]) {
    if (g.x >= y.get_width() || g.y >= y.get_height())
        return;
    float2 p = (float2(g) + .5) / float2(y.get_width(), y.get_height());
    float3 v = yuv(scene(p, t));
    y.write(float4(v.x, 0, 0, 1), g);
    if ((g.x % 2) == 0 && (g.y % 2) == 0)
        uv.write(float4(v.yz, 0, 1), g / 2);
}
kernel void convert(texture2d<float, access::sample> y [[texture(0)]],
                    texture2d<float, access::sample> uv [[texture(1)]],
                    texture2d<float, access::write> out [[texture(2)]],
                    uint2 g [[thread_position_in_grid]]) {
    if (g.x >= out.get_width() || g.y >= out.get_height())
        return;
    constexpr sampler s(filter::linear);
    float2 p = (float2(g) + .5) / float2(out.get_width(), out.get_height());
    float l = (y.sample(s, p).r * 255. - 16.) / 219.;
    float2 ch = (uv.sample(s, p).rg * 255. - 128.) / 224.;
    out.write(
        float4(clamp(float3(l + 1.5748 * ch.y, l - .1873 * ch.x - .4681 * ch.y, l + 1.8556 * ch.x),
                     0.,
                     1.),
               1),
        g);
}
struct V {
    float4 pos [[position]];
    float2 uv;
};
vertex V vert(uint i [[vertex_id]]) {
    float2 a = float2((i << 1) & 2, i & 2);
    return {float4(a * float2(2, -2) + float2(-1, 1), 0, 1), a};
}
fragment float4 frag(V v [[stage_in]],
                     texture2d<float> a [[texture(0)]],
                     texture2d<float> b [[texture(1)]],
                     texture2d<float> ref [[texture(2)]],
                     constant int &mode [[buffer(0)]],
                     constant float &aspect [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 p = v.uv;
    bool split = mode == 0 || mode == 4;
    bool right = p.x >= .5;
    if (split)
        p.x = fract(p.x * 2);
    float ar = aspect * (split ? .5 : 1.);
    if (ar < 1.77778)
        p.y = (p.y - .5) * 1.77778 / ar + .5;
    else
        p.x = (p.x - .5) * ar / 1.77778 + .5;
    if (any(p < 0) || any(p > 1))
        return float4(.035, .04, .05, 1);
    if (mode == 1)
        return b.sample(s, p);
    if (mode == 2)
        return ref.sample(s, p);
    if (mode == 3)
        return a.sample(s, p);
    if (mode == 4)
        return right ? ref.sample(s, p) : b.sample(s, p);
    if (mode == 5)
        return float4(min(abs(b.sample(s, p).rgb - ref.sample(s, p).rgb) * 5., 1.), 1);
    return right ? b.sample(s, p) : a.sample(s, p);
}