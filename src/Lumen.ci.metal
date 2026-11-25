// Ядро буста: SDR (линейный свет, рабочее пространство Core Image) → HDR.
// Усиление — скаляр на пиксель, поэтому цветность не меняется, и gain map
// в файле получается монохромной без потерь.
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" { namespace coreimage {

// s      — исходный пиксель (линейный, премультиплицированный)
// g      — слегка размытая копия: по ней считается маска, чтобы усиление было
//          гладким (gain map пишется в пониженном разрешении) и не рвало текстуру
// t      — порог: с какой яркости начинается подъём (Баланс)
// stops  — максимум подъёма в стопах (Сила), 1 стоп = ×2
float4 lumenBoost(sample_t s, sample_t g, float t, float stops) {
    float3 c = max(g.rgb, float3(0.0));
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    float m = max(c.r, max(c.g, c.b));
    // смесь яркости и максимума канала: насыщенные цвета на свету
    // (жёлтая ваза, листья) тоже светятся, а не только белое
    float v = pow(mix(y, m, 0.5), 1.0 / 2.2);
    float k = smoothstep(t, 1.0, v);
    return float4(s.rgb * exp2(stops * k), s.a);
}

}}
