// SwiftUI Metal shaders for Skelf. Compiled into the app's default.metallib (see build.sh /
// SwiftPM) so SwiftUI's ShaderLibrary can find these stitchable functions by name.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A water-style ripple that radiates from `origin`, used on the artwork popup (on appear and
// on click). Adapted from Apple's WWDC 2024 "Create custom visual effects with SwiftUI" sample:
// the displacement propagates outward (delayed by distance/speed), oscillates, and decays.
[[stitchable]] half4 skelfRipple(float2 position,
                                 SwiftUI::Layer layer,
                                 float2 origin,
                                 float time,
                                 float amplitude,
                                 float frequency,
                                 float decay,
                                 float speed) {
    float dist = length(position - origin);
    float delay = dist / speed;
    float t = max(0.0, time - delay);

    float ripple = amplitude * sin(frequency * t) * exp(-decay * t);
    float2 dir = dist > 0.0001 ? normalize(position - origin) : float2(0.0);

    half4 color = layer.sample(position + ripple * dir);
    // A faint highlight along the crest gives the wave some sheen.
    color.rgb += half3(0.3h * half(ripple / amplitude) * color.a);
    return color;
}
