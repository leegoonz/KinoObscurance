﻿//
// Deferred AO - SSAO image effect for deferred shading
//
// Copyright (C) 2015 Keijiro Takahashi
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
Shader "Hidden/DeferredAO"
{
    Properties
    {
        _MainTex("-", 2D) = "" {}
    }
    CGINCLUDE

    #include "UnityCG.cginc"

    #pragma multi_compile _ _RANGE_CHECK
    #pragma multi_compile _SAMPLE_LOW _SAMPLE_MEDIUM _SAMPLE_HIGH _SAMPLE_OVERKILL

    sampler2D _MainTex;
    float2 _MainTex_TexelSize;

    sampler2D _CameraDepthNormalsTexture;
	sampler2D_float _CameraDepthTexture;
    sampler2D _CameraGBufferTexture2;
    float4x4 _WorldToCamera;

    float _Intensity;
    float _Radius;
    float _FallOff;

    #if _SAMPLE_LOW
    static const int SAMPLE_COUNT = 8;
    #elif _SAMPLE_MEDIUM
    static const int SAMPLE_COUNT = 16;
    #elif _SAMPLE_HIGH
    static const int SAMPLE_COUNT = 24;
    #else
    static const int SAMPLE_COUNT = 80;
    #endif

    float nrand(float2 uv, float dx, float dy)
    {
        uv += float2(dx, dy + _Time.x);
        return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    }

    #define USE_IMP 1

    float3 spherical_kernel(float2 uv, float index)
    {
        // Uniformaly distributed points
        // http://mathworld.wolfram.com/SpherePointPicking.html
        float u = nrand(uv, 0, index) * 2 - 1;
        float theta = nrand(uv, 1, index) * UNITY_PI * 2;
        float u2 = sqrt(1 - u * u);
        float3 v = float3(u2 * cos(theta), u2 * sin(theta), u);
        // Adjustment for distance distribution.
        float l = index / SAMPLE_COUNT;
        return v * lerp(0.1, 1.0, sqrt(l));
    }

    float3 spherical_kernel2(float2 uv, float index)
    {
        float u = nrand(uv, 0, index);
        float r = sqrt(u);
        float theta = UNITY_PI * 2 * nrand(uv, 1, index);
        float x = r * cos(theta);
        float y = r * sin(theta);
        return float3(x, y, sqrt(1 - u)) * sqrt(nrand(uv, 2, index));
    }

    half4 frag_ao(v2f_img i) : SV_Target 
    {
        half4 src = tex2D(_MainTex, i.uv);

        // Sample a view-space normal vector.
        float depth_o;
        float3 norm_o;
        DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), depth_o, norm_o);
        depth_o *= _ProjectionParams.z;
        norm_o.z *= -1;

        // This early-out flow control is not allowed in HLSL.
        // if (depth_o > _FallOff) return src;

        // Reconstruct the view-space position.
        float2 p11_22 = float2(unity_CameraProjection._11, unity_CameraProjection._22);
        float2 p13_31 = float2(unity_CameraProjection._13, unity_CameraProjection._23);
        float3 pos_o = float3((i.uv * 2 - 1 - p13_31) / p11_22, 1) * depth_o;

        float3x3 proj = (float3x3)unity_CameraProjection;

        float3 norm_o_x = normalize(cross(float3(1, 0.1, 0.1), norm_o));
        float3 norm_o_y = cross(norm_o, norm_o_x);

        float occ = 0.0;
        for (int s = 0; s < SAMPLE_COUNT; s++)
        {
#if USE_IMP
            float3 delta = spherical_kernel2(i.uv, s);
            delta = norm_o_x * delta.x + norm_o_y * delta.y + norm_o * delta.z;
#else
            float3 delta = spherical_kernel(i.uv, s);

            // Wants a sample in normal oriented hemisphere.
            delta *= (dot(norm_o, delta) >= 0) * 2 - 1;
#endif

            // Sampling point.
            float3 pos_s = pos_o + delta * _Radius;

            // Re-project the sampling point.
            float3 pos_sc = mul(proj, pos_s);
            float2 uv_s = (pos_sc.xy / pos_s.z + 1) * 0.5;

            // Sample a linear depth at the sampling point.
            float depth_s;
            float3 norm_s;
            DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, uv_s), depth_s, norm_s);
            depth_s *= _ProjectionParams.z;

            // Occlusion test.
            float dist = pos_s.z - depth_s;
#if USE_IMP
            float cosine = 1;
#else
            float cosine = dot(norm_o, normalize(delta));
#endif
            #if _RANGE_CHECK
            occ += (dist > 0.01 * _Radius) * (dist < _Radius) * cosine;
            #else
            occ += (dist > 0.01 * _Radius) * cosine;
            #endif
        }

        float falloff = 1.0 - depth_o / _FallOff;
#if USE_IMP
        occ *= UNITY_PI;
#else
        occ *= UNITY_PI * 2;
#endif
        occ = saturate(occ * _Intensity * falloff / SAMPLE_COUNT);

        return half4(lerp(src.rgb, (half3)0.0, occ), src.a);
    }

    ENDCG
    SubShader
    {
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_ao
            #pragma target 3.0
            ENDCG
        }
    }
}
