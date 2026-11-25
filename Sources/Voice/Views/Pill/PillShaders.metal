// The pill's one body: a signed distance field of up to five rounded rectangles (the pill and the
// pieces that bud off it), blended with a smooth minimum so they melt into and out of each other.
//
// Geometry: `g` holds 6 floats per slot: x, y, width, height, corner radius, presence (0...1).
// Coordinates are points in the view the shader is applied to (top-left origin).
//
// pillPlate  - flat skins: fill, thin edge, soft shadow, progress glow.
// pillGlass  - glass skins: refracts the layer (a capture of what is behind the pill) through a
//              bevelled body with chromatic dispersion, a little frost, a bright rim, a specular
//              band, an inner shade and a tint, plus the same shadow and progress glow.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float sdRoundRect(float2 p, float2 centre, float2 halfSize, float radius) {
    float2 q = abs(p - centre) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

static float smin(float a, float b, float k) {
    if (k <= 0.0) return min(a, b);
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static float pillSDF(float2 p, device const float *g, int count, float k) {
    float d = 1e5;
    int slots = count / 6;
    for (int i = 0; i < slots; i++) {
        float w = g[i * 6 + 2], h = g[i * 6 + 3], presence = g[i * 6 + 5];
        if (presence <= 0.002 || w < 0.25 || h < 0.25) continue;
        float2 halfSize = float2(w, h) * 0.5;
        float r = min(g[i * 6 + 4], min(halfSize.x, halfSize.y));
        float di = sdRoundRect(p, float2(g[i * 6], g[i * 6 + 1]) + halfSize, halfSize, r);
        d = d > 9e4 ? di : smin(d, di, k);
    }
    return d;
}

static float2 pillNormal(float2 p, device const float *g, int count, float k) {
    float e = 0.75;
    float dx = pillSDF(p + float2(e, 0), g, count, k) - pillSDF(p - float2(e, 0), g, count, k);
    float dy = pillSDF(p + float2(0, e), g, count, k) - pillSDF(p - float2(0, e), g, count, k);
    float2 n = float2(dx, dy);
    float len = length(n);
    return len > 1e-4 ? n / len : float2(0, 0);
}

/// The progress glow: a bright rounded bar of light inside a dark track, with a soft bloom that bleeds
/// past the bar, lights the glass around it and spills a little outside the body.
/// `glow.x` = fill 0...1 (negative = off), `glow.y` = sheen phase 0...1, `glow.z` = completion flash
/// 0...1, `glow.w` = strength 0...1. The bar runs along the body's long side: left to right on a
/// wide body, bottom to top on a tall one (side docks).
struct GlowSample {
    float core;     // 0...1 coverage of the bright bar
    float lum;      // the bar's brightness where it covers (core, sheen)
    float halo;     // bloom light at this point (inside and outside the bar)
    float track;    // 0...1 coverage of the track the bar runs in
};

static GlowSample progressGlow(float2 p, device const float *g, float4 glow, float pixel) {
    GlowSample o = { 0.0, 0.0, 0.0, 0.0 };
    if (glow.x < 0.0 || glow.w <= 0.001) return o;
    float x = g[0], y = g[1], w = max(g[2], 1.0), h = max(g[3], 1.0);
    bool vertical = h > w * 1.15;
    float shortSide = vertical ? w : h;
    float inset = clamp(shortSide * 0.1, 2.0, 3.5);
    float2 trackOrigin = float2(x + inset, y + inset);
    float2 trackSize = max(float2(w, h) - 2.0 * inset, float2(1.0));
    float trackRadius = min(max(g[4] - inset, 0.0), min(trackSize.x, trackSize.y) * 0.5);
    float2 trackHalf = trackSize * 0.5;
    float td = sdRoundRect(p, trackOrigin + trackHalf, trackHalf, trackRadius);
    o.track = smoothstep(pixel, -pixel, td);

    float f = clamp(glow.x, 0.0, 1.0);
    float2 fillSize, fillOrigin;
    float u;  // 0 at the start of the track, 1 at its end
    if (vertical) {
        fillSize = float2(trackSize.x, max(0.5, trackSize.y * f));
        fillOrigin = float2(trackOrigin.x, trackOrigin.y + trackSize.y - fillSize.y);
        u = (trackOrigin.y + trackSize.y - p.y) / trackSize.y;
    } else {
        fillSize = float2(max(0.5, trackSize.x * f), trackSize.y);
        fillOrigin = trackOrigin;
        u = (p.x - trackOrigin.x) / trackSize.x;
    }
    float2 fillHalf = fillSize * 0.5;
    float fillRadius = min(trackRadius, min(fillHalf.x, fillHalf.y));
    float fd = sdRoundRect(p, fillOrigin + fillHalf, fillHalf, fillRadius);
    // A very short bar is thin as well as short, so 2 % reads as a sliver of light, not a dot.
    float presence = smoothstep(0.0, 0.035, f);
    o.core = smoothstep(pixel, -pixel, fd) * presence;
    // Brightest along the bar's middle, a touch softer toward its sides; a sheen walks along it.
    float depth = clamp(-fd / max(min(fillHalf.x, fillHalf.y), 1.0), 0.0, 1.0);
    float band = (glow.y * 1.5 - 0.25) * max(f, 0.2);
    float sheen = exp(-pow((u - band) / 0.11, 2.0));
    o.lum = 0.86 + 0.1 * smoothstep(0.0, 0.55, depth) + 0.1 * sheen;
    // Bloom: a tight bright falloff and a wide soft one, both stronger at the leading edge.
    float outside = max(fd, 0.0);
    float lead = vertical ? smoothstep(fillOrigin.y + 6.0, fillOrigin.y - 4.0, p.y)
                          : smoothstep(fillOrigin.x + fillSize.x - 6.0, fillOrigin.x + fillSize.x + 4.0, p.x);
    float spread = 1.0 + 0.9 * glow.z;
    o.halo = (exp(-outside / (4.5 * spread)) * 0.85 + exp(-outside / (13.0 * spread)) * 0.42) * (1.0 + 0.25 * lead) * presence;
    return o;
}

/// Lights a pixel inside the body with the glow: darkens the track, lays the bloom over it, then the bar.
static float3 applyGlow(float3 rgb, GlowSample gs, float4 glow) {
    float s = clamp(glow.w, 0.0, 1.0);
    float flash = clamp(glow.z, 0.0, 1.0);
    float3 white = float3(1.0, 0.995, 0.985);
    rgb = mix(rgb, float3(0.018, 0.018, 0.022), 0.82 * gs.track * s);
    float halo = gs.halo * (0.34 + 0.5 * flash) * s;
    rgb += white * halo * (1.0 - gs.core);
    rgb = mix(rgb, white * min(1.0, gs.lum + 0.2 * flash), gs.core * s);
    rgb += white * flash * 0.14 * s;
    return rgb;
}

/// The bloom that spills outside the body, as premultiplied white light.
static float outerGlow(GlowSample gs, float4 glow) {
    float s = clamp(glow.w, 0.0, 1.0);
    return clamp(gs.halo * (0.42 + 0.45 * clamp(glow.z, 0.0, 1.0)) * s, 0.0, 0.85);
}

[[ stitchable ]] half4 pillPlate(float2 p, half4 color,
                                 device const float *g, int count,
                                 float k, float pixel,
                                 half4 fill, half4 edge, float edgeWidth,
                                 half4 shadow, float shadowRadius, float shadowY,
                                 half4 light, float4 glow, float2 pointer, float hover) {
    float d = pillSDF(p, g, count, k);
    float coverage = smoothstep(pixel, -pixel, d);
    // Soft shadow, under the body only.
    float ds = pillSDF(p - float2(0, shadowY), g, count, k);
    float shadowAlpha = float(shadow.a) * (1.0 - smoothstep(-shadowRadius * 0.4, shadowRadius, ds)) * (1.0 - coverage);
    GlowSample gs = progressGlow(p, g, glow, pixel);
    if (coverage <= 0.0) {
        float bloom = outerGlow(gs, glow);
        float sa = shadowAlpha * (1.0 - bloom);
        return half4(half3(float3(1.0) * bloom + float3(shadow.rgb) * sa), half(bloom + sa));
    }

    float3 rgb = float3(fill.rgb);
    float alpha = float(fill.a);
    (void)light;
    if (hover > 0.0) {
        float spot = smoothstep(46.0, 0.0, length(p - pointer)) * 0.02 * hover;
        rgb += spot;
    }
    // One thin straight edge.
    float rim = smoothstep(-edgeWidth - pixel, -edgeWidth + pixel, d);
    rgb = mix(rgb, float3(edge.rgb), rim * float(edge.a));
    alpha = max(alpha, rim * float(edge.a));
    // The progress glow lights the plate (and makes it opaque where it shines).
    if (glow.x >= 0.0) {
        rgb = clamp(applyGlow(rgb, gs, glow), 0.0, 1.0);
        alpha = mix(alpha, 1.0, clamp(glow.w, 0.0, 1.0) * 0.9);
    }
    float a = alpha * coverage;
    // Inside the antialiased rim the outer bloom still shows through.
    float bloom = outerGlow(gs, glow) * (1.0 - a);
    float s = shadowAlpha * (1.0 - a - bloom);
    return half4(half3(rgb * a + float3(1.0) * bloom + float3(shadow.rgb) * max(s, 0.0)), half(a + bloom + max(s, 0.0)));
}

/// Frosted sample: the centre and eight taps on a ring of radius `r`.
static float3 frosted(SwiftUI::Layer layer, float2 q, float r) {
    if (r <= 0.01) return float3(layer.sample(q).rgb);
    float3 c = float3(layer.sample(q).rgb) * 2.0;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.785398;
        c += float3(layer.sample(q + float2(cos(a), sin(a)) * r).rgb);
    }
    return c / 10.0;
}

[[ stitchable ]] half4 pillGlass(float2 p, SwiftUI::Layer layer,
                                 device const float *g, int count,
                                 float k, float pixel,
                                 half4 tint, half4 rimColor, float bevel, float refraction,
                                 float dispersion, float frost, float magnify, float dark, float saturation,
                                 half4 shadow, float shadowRadius, float shadowY,
                                 half4 light, float4 glow, float2 pointer, float hover, float drift) {
    float d = pillSDF(p, g, count, k);
    float coverage = smoothstep(pixel, -pixel, d);
    float ds = pillSDF(p - float2(0, shadowY), g, count, k);
    float shadowAlpha = float(shadow.a) * (1.0 - smoothstep(-shadowRadius * 0.4, shadowRadius, ds)) * (1.0 - coverage);
    GlowSample gs = progressGlow(p, g, glow, pixel);
    if (coverage <= 0.0) {
        float bloom = outerGlow(gs, glow);
        float sa = shadowAlpha * (1.0 - bloom);
        return half4(half3(float3(1.0) * bloom + float3(shadow.rgb) * sa), half(bloom + sa));
    }

    // Surface: a circular bevel `bevel` points wide, flat in the middle. `s` runs 0 (flat) to 1
    // (rim); `bend` is the bevel's slope, near zero inside and steep at the rim.
    float2 n = pillNormal(p, g, count, k);
    float s = clamp(1.0 + d / bevel, 0.0, 1.0);
    float bend = 1.0 - sqrt(max(0.0, 1.0 - s * s));

    // Approved look (21 Nov 2026 mockup, skins Jet / Clear / Liquid): thin crisp glass. A lens bend at
    // the rim, frost and tint from the skin, the rim picking up the colour just outside it, one sharp
    // hairline of edge light, a faint prism only on the lit bevel. Cards (big bodies) frost and darken
    // more so their words always read.
    float2 centre = float2(g[0] + g[2] * 0.5, g[1] + g[3] * 0.5);
    float big = clamp((min(g[2], g[3]) - 60.0) / 70.0, 0.0, 1.0);
    float2 offset = (centre - p) * magnify * (1.0 - s) * (1.0 - big) - n * refraction * bend;
    float2 spread = n * dispersion * (0.2 + bend);
    float blur = frost + big * 9.0;
    float3 col;
    col.r = frosted(layer, p + offset - spread, blur).r;
    col.g = frosted(layer, p + offset, blur).g;
    col.b = frosted(layer, p + offset + spread, blur).b;
    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = mix(float3(luma), col, saturation);
    float3 tintRGB = mix(float3(tint.rgb), float3(0.03, 0.03, 0.04), big * 0.85);
    float tintAmount = mix(float(tint.a), max(float(tint.a), 0.8), big);
    col = mix(col, tintRGB, tintAmount * mix(0.85, 1.0, 1.0 - s));
    (void)drift;

    float2 lightDir = normalize(float2(-0.35, -0.94));
    float facing = max(0.0, dot(n, lightDir));
    float back = max(0.0, dot(n, -lightDir));
    float lit = pow(facing, 1.5) + 0.4 * pow(back, 2.0);
    // Environment light: the rim takes on what is just outside it.
    float3 env = frosted(layer, p + n * 22.0, 8.0);
    float envAmount = dark > 0.5 ? 0.25 : 0.32;
    col += env * envAmount * smoothstep(0.55, 1.0, s) * (0.35 + 0.65 * lit);
    // Prism: a faint spectrum across the lit bevel only.
    float3 prism = 0.5 + 0.5 * cos(6.2831 * (s * 1.3 + float3(0.0, 0.33, 0.67)));
    col += (prism - 0.5) * dispersion * 0.06 * smoothstep(0.45, 0.9, s) * lit;
    // A whisper of light inside, brighter toward the top.
    float vertical = clamp((p.y - g[1]) / max(g[3], 1.0), 0.0, 1.0);
    col += (dark > 0.5 ? 0.03 : 0.05) * (1.0 - vertical) * (1.0 - vertical) * (1.0 - s);
    // Rim: thin Fresnel plus one sharp specular streak, then a crisp 1 px hairline of edge light.
    col += float3(rimColor.rgb) * (pow(s, 6.0) * 0.12 * (0.3 + lit) + pow(facing, 14.0) * smoothstep(0.75, 1.0, s) * 0.5)
        * float(rimColor.a);
    float hairline = smoothstep(-0.9 - pixel, -0.15, d) * (1.0 - smoothstep(-0.15, 0.4, d));
    col = mix(col, float3(rimColor.rgb), hairline * (0.35 + 0.65 * lit + 0.05 * hover) * float(rimColor.a));

    // The progress glow: a dark track, the bright bar and its bloom lighting the glass and the rim.
    (void)light;
    if (glow.x >= 0.0) col = applyGlow(col, gs, glow);
    // Hover: no cursor-following spotlight beyond a faint lift.
    if (hover > 0.0) col += smoothstep(52.0, 0.0, length(p - pointer)) * 0.02 * hover;

    col = clamp(col, 0.0, 1.0);
    float a = coverage;
    float bloom = outerGlow(gs, glow) * (1.0 - a);
    float sh = max(0.0, shadowAlpha * (1.0 - a - bloom));
    return half4(half3(col * a + float3(1.0) * bloom + float3(shadow.rgb) * sh), half(a + bloom + sh));
}
