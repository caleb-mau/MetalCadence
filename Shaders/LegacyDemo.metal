#include <metal_stdlib>
using namespace metal;
float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}
float3 scene(float2 uv, float t) {
    float2 p = uv * 2 - 1;
    p.x *= 1.7778;
    float bend = .17 * sin(t * 1.0472);
    float horizon = -.19;
    float3 c = mix(float3(.16, .32, .55), float3(.75, .80, .84), clamp((p.y + 1) * .75, 0., 1.));
    float sun = length(p - float2(.85, -.72));
    c += float3(.8, .52, .2) * exp(-sun * sun * 18);
    if (p.y < horizon) {
        float bx = (p.x + bend) * 8;
        float k = floor(bx);
        float ht = .10 + hash(float2(k, 2)) * .56;
        if (p.y > horizon - ht) {
            float2 q = float2(fract(bx), (p.y - horizon + ht) * 20);
            c = float3(.10, .14, .20) + hash(float2(k, 1)) * .11;
            float windows = step(.24, fract(q.x * 4)) * step(fract(q.x * 4), .78) *
                            step(.22, fract(q.y)) * step(fract(q.y), .64);
            c += windows * float3(.45, .30, .12) *
                 step(.35, hash(float2(floor(q.x * 4) + k * 7, floor(q.y))));
        }
    }
    if (p.y >= horizon) {
        float z = 1.0 / max(.025, p.y - horizon);
        float x = (p.x - bend * (1. - .4 / (z + 1))) * z;
        float road = abs(x);
        float tile = floor(z * 2 + t * 9);
        float noise = hash(floor(float2(x * 75, z * 40 + t * 180)));
        c = float3(.16, .19, .21) + noise * .07;
        if (road > 1.5) {
            c = float3(.12, .24, .10) + noise * .13;
            if (road < 1.72)
                c = mix(float3(.7, .7, .65), float3(.7, .09, .06), step(.5, fract(z * 2 + t * 8)));
        } else {
            if (abs(road - 1.43) < .035)
                c = float3(.85, .82, .62);
            if (abs(x) < .024 && fract(z * .7 + t * 3) > .43)
                c = float3(.9, .88, .74);
        }
        for (int i = 0; i < 8; i++) {
            float zz = 1.0 + float(i) * 1.4 + fmod(t * 1.4, 1.4);
            float side = (i % 2 == 0 ? -1. : 1.);
            float xx = side * (2.1 + hash(float2(i, 4)) * .5) / zz + bend;
            float yy = horizon + 1. / zz;
            float2 d = p - float2(xx, yy);
            float r = .24 / zz;
            if (abs(d.x) < .032 / zz && d.y < 0 && d.y > -.65 / zz)
                c = float3(.22, .13, .075);
            if (length((d + float2(0, .49 / zz)) * float2(1, .75)) < r)
                c = float3(.09, .25, .12) + noise * .1;
        }
    }
    float cx = .35 * sin(t * 1.0472);
    float2 car = p - float2(cx, .43);
    if (abs(car.x) < .23 && car.y > -.10 && car.y < .11) {
        c = float3(.62, .07, .04) * (1. - .6 * abs(car.y));
        if (car.y < -.035 && abs(car.x) < .17)
            c = float3(.14, .24, .32);
        if (car.y > .045 && abs(car.x) > .115)
            c = float3(1, .15, .04);
        if (car.y > .075 && abs(car.x) < .08)
            c = float3(.8, .8, .72);
    }
    float2 hud = uv - float2(.87, .86);
    if (length(hud) < .085 && length(hud) > .079)
        c = float3(.85);
    if (abs(hud.y) < .002 && abs(hud.x) < .06)
        c = float3(.9);
    return clamp(c, 0., 1.);
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