#include <metal_stdlib>
using namespace metal;

struct KeyLightRefractionUniforms {
    float4 viewport;
    float4 optics;
    float4 tuning;
    uint4 counts;
};

struct KeyLightRefractionSurface {
    float4 frame;
    float4 optical;
};

struct KeyLightRefractionVertexOut {
    float4 position [[position]];
};

vertex KeyLightRefractionVertexOut keyLightRefractionVertex(
    uint vertexID [[vertex_id]]
) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    KeyLightRefractionVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    return output;
}

static float keyLightRoof(
    float normalizedX,
    float smoothness
) {
    const float x = abs(normalizedX);
    if (x >= 1.0) {
        return 0.0;
    }

    // Current Wave: the same compact-to-wide plateau relationship used by
    // LiquidGlassBellShape. Smoothstep is the continuous cubic shoulder.
    const float shoulderShare =
        0.12 + 0.30 * pow(clamp(smoothness, 0.0, 1.0), 1.55);
    const float plateauEdge = max(1.0 - 2.0 * shoulderShare, 0.02);
    return 1.0 - smoothstep(plateauEdge, 1.0, x);
}

static float keyLightSurfaceHeight(
    float2 point,
    KeyLightRefractionSurface surface
) {
    const float visibility = clamp(surface.optical.x, 0.0, 1.0);
    const float emergence = clamp(surface.optical.y, 0.0, 1.0);
    const float smoothness = clamp(surface.optical.z, 0.0, 1.0);
    const float flow = clamp(surface.optical.w, -1.0, 1.0);
    if (visibility <= 0.0001 || emergence <= 0.0001) {
        return 0.0;
    }

    const float materialWidth =
        surface.frame.z * (0.28 + 0.72 * emergence);
    const float centerX =
        surface.frame.x + surface.frame.z * 0.5
        + materialWidth * 0.045 * flow * emergence;
    const float baselineY = surface.frame.y + surface.frame.w * 0.72;
    const float rise = max(surface.frame.w * 0.72 * emergence, 0.5);
    const float normalizedX =
        (point.x - centerX) / max(materialWidth * 0.5, 0.5);
    const float roof = keyLightRoof(
        normalizedX,
        smoothness
    );
    if (roof <= 0.0) {
        return 0.0;
    }

    const float vertical = (baselineY - point.y) / rise;
    const float throughLens = vertical / max(roof, 0.0001);
    if (abs(throughLens) >= 1.0) {
        return 0.0;
    }

    // The visible display cuts through the center of a convex optical surface.
    // Its lower half continues behind the bezel instead of terminating at the
    // screen edge. Consequently the thickness and its vertical derivative are
    // continuous at the bottom crop; only the open top and side silhouette can
    // produce a refractive boundary.
    const float verticalArc = sqrt(
        max(1.0 - throughLens * throughLens, 0.0)
    );
    return visibility
        * pow(roof, 0.70)
        * pow(verticalArc, 0.72);
}

static float keyLightSurfaceDomain(
    float2 point,
    KeyLightRefractionSurface surface
) {
    const float visibility = clamp(surface.optical.x, 0.0, 1.0);
    const float emergence = clamp(surface.optical.y, 0.0, 1.0);
    const float smoothness = clamp(surface.optical.z, 0.0, 1.0);
    const float flow = clamp(surface.optical.w, -1.0, 1.0);
    if (visibility <= 0.0001 || emergence <= 0.0001) {
        return -100000.0;
    }

    const float materialWidth =
        surface.frame.z * (0.28 + 0.72 * emergence);
    const float centerX =
        surface.frame.x + surface.frame.z * 0.5
        + materialWidth * 0.045 * flow * emergence;
    const float baselineY = surface.frame.y + surface.frame.w * 0.72;
    const float rise = max(surface.frame.w * 0.72 * emergence, 0.5);
    const float normalizedX =
        (point.x - centerX) / max(materialWidth * 0.5, 0.5);
    const float roof = keyLightRoof(normalizedX, smoothness);
    const float vertical = (baselineY - point.y) / rise;

    // This is a signed coverage field for the open upper lens. There is no
    // bottom term: the glass continues below the drawable and the view clips it.
    const float horizontalDomain = 1.0 - abs(normalizedX);
    const float topDomain = roof - vertical;
    return min(horizontalDomain, topDomain);
}

static float keyLightSmoothMaximum(float left, float right, float radius) {
    if (left <= 0.0) {
        return right;
    }
    if (right <= 0.0) {
        return left;
    }
    const float h = clamp(
        0.5 + 0.5 * (left - right) / max(radius, 0.0001),
        0.0,
        1.0
    );
    return mix(right, left, h) + radius * h * (1.0 - h);
}

static float keyLightSurfaceCenterX(
    KeyLightRefractionSurface surface
) {
    const float emergence = clamp(surface.optical.y, 0.0, 1.0);
    const float flow = clamp(surface.optical.w, -1.0, 1.0);
    const float materialWidth =
        surface.frame.z * (0.28 + 0.72 * emergence);
    return surface.frame.x + surface.frame.z * 0.5
        + materialWidth * 0.045 * flow * emergence;
}

static float keyLightHeightField(
    float2 point,
    constant KeyLightRefractionUniforms &uniforms,
    constant KeyLightRefractionSurface *surfaces
) {
    float strongest = 0.0;
    float second = 0.0;
    float strongestCenterX = 0.0;
    float secondCenterX = 0.0;
    float strongestSmoothness = 0.0;
    float secondSmoothness = 0.0;
    const uint count = min(uniforms.counts.x, 32u);
    for (uint index = 0u; index < count; ++index) {
        const float candidate = keyLightSurfaceHeight(
            point,
            surfaces[index]
        );
        const float candidateCenterX =
            keyLightSurfaceCenterX(surfaces[index]);
        const float candidateSmoothness =
            clamp(surfaces[index].optical.z, 0.0, 1.0);
        if (candidate > strongest) {
            second = strongest;
            secondCenterX = strongestCenterX;
            secondSmoothness = strongestSmoothness;
            strongest = candidate;
            strongestCenterX = candidateCenterX;
            strongestSmoothness = candidateSmoothness;
        } else if (candidate > second) {
            second = candidate;
            secondCenterX = candidateCenterX;
            secondSmoothness = candidateSmoothness;
        }
    }

    if (second <= 0.0) {
        return strongest;
    }

    const float leftCenterX = min(strongestCenterX, secondCenterX);
    const float rightCenterX = max(strongestCenterX, secondCenterX);
    const float centerDistance = rightCenterX - leftCenterX;
    if (centerDistance <= 0.5
        || point.x <= leftCenterX
        || point.x >= rightCenterX) {
        return strongest;
    }

    // Smooth-union only the saddle between two real key centers. The blend
    // weight is exactly zero at both centers and everywhere outside them, so
    // neither key's peak nor either exterior shoulder can move.
    const float interiorT =
        clamp((point.x - leftCenterX) / centerDistance, 0.0, 1.0);
    const float interiorWeight =
        4.0 * interiorT * (1.0 - interiorT);
    const float averageSmoothness =
        0.5 * (strongestSmoothness + secondSmoothness);
    const float blendRadius =
        (0.035 + 0.025 * averageSmoothness) * interiorWeight;
    return keyLightSmoothMaximum(
        strongest,
        second,
        blendRadius
    );
}

static float keyLightDomainField(
    float2 point,
    constant KeyLightRefractionUniforms &uniforms,
    constant KeyLightRefractionSurface *surfaces
) {
    float domain = -100000.0;
    const uint count = min(uniforms.counts.x, 32u);
    for (uint index = 0u; index < count; ++index) {
        domain = max(
            domain,
            keyLightSurfaceDomain(point, surfaces[index])
        );
    }
    return domain;
}

static float2 keyLightBoundedOffset(
    float2 offset,
    float maximumLength
) {
    const float lengthSquared = dot(offset, offset);
    const float maximumSquared = maximumLength * maximumLength;
    if (lengthSquared <= maximumSquared || lengthSquared <= 0.000001) {
        return offset;
    }
    return offset * (maximumLength * rsqrt(lengthSquared));
}

// The lens is attached to the physical bottom edge of the display. An ideal
// infinite plano-convex surface would bend its upper-face ray farther down,
// where this product has no screen content to sample. Constrain that component
// to the screen-facing hemisphere while preserving lateral dispersion. This
// models the opaque bezel boundary instead of stretching one nonexistent row.
static float2 keyLightScreenFacingOffset(float2 offset) {
    return float2(offset.x, -abs(offset.y));
}

// A side key can still refract beyond the left or right display boundary.
// Mirror the nearest valid gradient once instead of repeating a single border
// texel. The bounded optical path is far smaller than one texture dimension,
// so one reflection is sufficient.
static float keyLightMirroredUnitCoordinate(float coordinate) {
    if (coordinate < 0.0) {
        return min(-coordinate, 1.0);
    }
    if (coordinate > 1.0) {
        return max(2.0 - coordinate, 0.0);
    }
    return coordinate;
}

static float2 keyLightValidBackdropUV(
    float2 uv,
    texture2d<float> backdrop
) {
    const float2 textureSize = max(
        float2(backdrop.get_width(), backdrop.get_height()),
        float2(1.0)
    );
    const float2 halfTexel = 0.5 / textureSize;
    const float2 mirrored = float2(
        keyLightMirroredUnitCoordinate(uv.x),
        keyLightMirroredUnitCoordinate(uv.y)
    );
    return clamp(mirrored, halfTexel, 1.0 - halfTexel);
}

static float3 keyLightBackdropColor(
    texture2d<float> backdrop,
    sampler backdropSampler,
    float2 uv
) {
    const float4 sample = backdrop.sample(
        backdropSampler,
        keyLightValidBackdropUV(uv, backdrop)
    );
    // Display captures are normally opaque. Multiplying by alpha makes clear
    // ScreenCaptureKit padding resolve to transparent black instead of exposing
    // undefined or white RGB payloads.
    return sample.rgb * clamp(sample.a, 0.0, 1.0);
}

fragment float4 keyLightRefractionFragment(
    KeyLightRefractionVertexOut input [[stage_in]],
    constant KeyLightRefractionUniforms &uniforms [[buffer(0)]],
    constant KeyLightRefractionSurface *surfaces [[buffer(1)]],
    texture2d<float> capturedBackdrop [[texture(0)]]
) {
    constexpr sampler backdropSampler(
        min_filter::linear,
        mag_filter::linear,
        mip_filter::none,
        address::clamp_to_edge,
        coord::normalized
    );

    const float2 drawableSize = max(
        uniforms.optics.zw,
        float2(1.0)
    );
    const float2 viewSize = max(
        uniforms.viewport.xy,
        float2(1.0)
    );
    const float2 point = input.position.xy * viewSize / drawableSize;
    const float domain = keyLightDomainField(
        point,
        uniforms,
        surfaces
    );
    const float domainAntialias = max(fwidth(domain) * 0.72, 0.00025);
    const float coverage = smoothstep(
        -domainAntialias,
        domainAntialias,
        domain
    );
    if (coverage <= 0.0001) {
        return float4(0.0);
    }

    const float centerHeight = keyLightHeightField(
        point,
        uniforms,
        surfaces
    );
    if (centerHeight <= 0.0001) {
        return float4(0.0);
    }

    // One drawable pixel in point coordinates gives a stable normal at both
    // 1x and Retina scale without quantizing the analytic contour.
    const float epsilon = max(
        max(viewSize.x / drawableSize.x, viewSize.y / drawableSize.y),
        0.35
    );
    const float2 gradient = float2(
        keyLightHeightField(
            point + float2(epsilon, 0.0),
            uniforms,
            surfaces
        ) - keyLightHeightField(
            point - float2(epsilon, 0.0),
            uniforms,
            surfaces
        ),
        keyLightHeightField(
            point + float2(0.0, epsilon),
            uniforms,
            surfaces
        ) - keyLightHeightField(
            point - float2(0.0, epsilon),
            uniforms,
            surfaces
        )
    ) / (2.0 * epsilon);

    // The height field is dimensionless. This converts it to the slope of the
    // curved front interface; the rear interface is assumed flat and parallel
    // to the display for a low-cost thin-lens approximation.
    const float3 normal = normalize(float3(-gradient * 17.0, 1.0));
    const float3 incident = float3(0.0, 0.0, -1.0);

    // SCHOTT N-BK7 catalogue indices at the C, e, and F spectral lines.
    // Red 1.51432, green 1.51872, blue 1.52238.
    const float3 transmittedRed = refract(incident, normal, 1.0 / 1.51432);
    const float3 transmittedGreen = refract(incident, normal, 1.0 / 1.51872);
    const float3 transmittedBlue = refract(incident, normal, 1.0 / 1.52238);
    const float pathLengthMultiplier =
        clamp(uniforms.tuning.x, 0.5, 2.5);
    const float transmissionOffsetLimit =
        clamp(uniforms.tuning.y, 13.0, 65.0);
    const float effectiveThickness =
        (4.0 + 10.0 * centerHeight)
        * uniforms.optics.x
        * pathLengthMultiplier;

    const float2 redOffset = keyLightBoundedOffset(
        keyLightScreenFacingOffset(
            transmittedRed.xy / max(abs(transmittedRed.z), 0.16)
                * effectiveThickness
        ),
        transmissionOffsetLimit
    );
    const float2 greenOffset = keyLightBoundedOffset(
        keyLightScreenFacingOffset(
            transmittedGreen.xy / max(abs(transmittedGreen.z), 0.16)
                * effectiveThickness
        ),
        transmissionOffsetLimit
    );
    const float2 blueOffset = keyLightBoundedOffset(
        keyLightScreenFacingOffset(
            transmittedBlue.xy / max(abs(transmittedBlue.z), 0.16)
                * effectiveThickness
        ),
        transmissionOffsetLimit
    );

    const float captureHeight = max(uniforms.viewport.z, viewSize.y);
    const float captureTopInset =
        max(captureHeight - viewSize.y, 0.0);

    const float2 redUV = float2(
        (point.x + redOffset.x) / viewSize.x,
        (captureTopInset + point.y + redOffset.y) / captureHeight
    );
    const float2 greenUV = float2(
        (point.x + greenOffset.x) / viewSize.x,
        (captureTopInset + point.y + greenOffset.y) / captureHeight
    );
    const float2 blueUV = float2(
        (point.x + blueOffset.x) / viewSize.x,
        (captureTopInset + point.y + blueOffset.y) / captureHeight
    );

    const float3 redSample = keyLightBackdropColor(
        capturedBackdrop,
        backdropSampler,
        redUV
    );
    const float3 greenSample = keyLightBackdropColor(
        capturedBackdrop,
        backdropSampler,
        greenUV
    );
    const float3 blueSample = keyLightBackdropColor(
        capturedBackdrop,
        backdropSampler,
        blueUV
    );
    const float3 transmittedColor = float3(
        redSample.r,
        greenSample.g,
        blueSample.b
    );

    // Schlick Fresnel with the N-BK7 green-line index: F0 ≈ 0.04216.
    const float f0 = 0.04216;
    const float cosTheta = clamp(abs(normal.z), 0.0, 1.0);
    const float fresnel =
        f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);

    // A screen overlay cannot observe the room behind the viewer. Use one
    // nearby backdrop sample as a bounded environment proxy instead of
    // inventing a white or gray reflection. On a uniform backdrop this remains
    // uniform, as real clear glass should.
    const float3 reflectedRay = reflect(incident, normal);
    const float reflectionDistance =
        3.0 + 7.0 * clamp(uniforms.optics.y, 0.0, 1.0);
    const float2 reflectionOffset = keyLightBoundedOffset(
        keyLightScreenFacingOffset(
            reflectedRay.xy / max(abs(reflectedRay.z), 0.24)
                * reflectionDistance
        ),
        20.0
    );
    const float2 reflectedUV = float2(
        (point.x + reflectionOffset.x) / viewSize.x,
        (captureTopInset + point.y + reflectionOffset.y) / captureHeight
    );
    const float3 reflectedColor = keyLightBackdropColor(
        capturedBackdrop,
        backdropSampler,
        reflectedUV
    );
    const float reflectedShare = clamp(
        fresnel
            * (0.36 + 0.54 * clamp(uniforms.optics.y, 0.0, 1.0)),
        0.0,
        0.82
    );
    const float3 finalColor = mix(
        transmittedColor,
        reflectedColor,
        reflectedShare
    );

    // Only steep top and side normals replace the real backdrop with the
    // refracted sample. The flat interior contributes zero color and zero
    // opacity, so there is no synthetic body fill to turn gray or white.
    const float edgeEnergy = smoothstep(
        0.055,
        0.72,
        1.0 - cosTheta
    );
    const float presence = smoothstep(0.0005, 0.045, centerHeight);
    const float userEdgeStrength =
        clamp(uniforms.optics.y, 0.0, 1.0);
    const float savedOpacity =
        clamp(uniforms.viewport.w, 0.0, 1.0);
    const float edgeOpacity =
        0.70 + 0.22 * userEdgeStrength + 0.08 * (1.0 - savedOpacity);
    const float alpha = coverage
        * presence
        * edgeEnergy
        * edgeOpacity;
    return float4(finalColor * alpha, alpha);
}
