cbuffer constants : register(b0) {
	int2 srcSize : packoffset(c0.x);
	int2 destSize : packoffset(c0.z);
};

#define MAGPIE_INPUT_COUNT 1
#include "common.hlsli"


 // Filtering for a given tap for the scalar.
void FsrEasuTap(
	inout float3 aC, // Accumulated color, with negative lobe.
	inout float aW, // Accumulated weight.
	float2 off, // Pixel offset from resolve position to tap.
	float2 dir, // Gradient direction.
	float2 len, // Length.
	float lob, // Negative lobe strength.
	float clp, // Clipping point.
	float3 c  // Tap color.
) { 
	// Rotate offset by direction.
	float2 v;
	v.x = (off.x * (dir.x)) + (off.y * dir.y);
	v.y = (off.x * (-dir.y)) + (off.y * dir.x);
	// Anisotropy.
	v *= len;
	// Compute distance^2.
	float d2 = v.x * v.x + v.y * v.y;
	// Limit to the window as at corner, 2 taps can easily be outside.
	d2 = min(d2, clp);
	// Approximation of lanczos2 without sin() or rcp(), or sqrt() to get x.
	//  (25/16 * (2/5 * x^2 - 1)^2 - (25/16 - 1)) * (1/4 * x^2 - 1)^2
	//  |_______________________________________|   |_______________|
	//                   base                             window
	// The general form of the 'base' is,
	//  (a*(b*x^2-1)^2-(a-1))
	// Where 'a=1/(2*b-b^2)' and 'b' moves around the negative lobe.
	float wB = 2.0f / 5.0f * d2 - 1;
	float wA = lob * d2 - 1;
	wB *= wB;
	wA *= wA;
	wB = 25.0f / 16.0f * wB -(25.0f / 16.0f - 1.0f);
	float w = wB * wA;
	// Do weighted average.
	aC += c * w; aW += w;
}

 // Accumulate direction and length.
void FsrEasuSet(
	inout float2 dir,
	inout float len,
	float2 pp,
	bool biS, bool biT, bool biU, bool biV,
	float lA, float lB, float lC, float lD, float lE) {
	// Compute bilinear weight, branches factor out as predicates are compiler time immediates.
	//  s t
	//  u v
	float w = 0;
	if (biS)w = (1 - pp.x) * (1 - pp.y);
	if (biT)w = pp.x * (1 - pp.y);
	if (biU)w = (1.0 - pp.x) * pp.y;
	if (biV)w = pp.x * pp.y;
	// Direction is the '+' diff.
	//    a
	//  b c d
	//    e
	// Then takes magnitude from abs average of both sides of 'c'.
	// Length converts gradient reversal to 0, smoothly to non-reversal at 1, shaped, then adding horz and vert terms.
	float dc = lD - lC;
	float cb = lC - lB;
	float lenX = max(abs(dc), abs(cb));
	lenX = rcp(lenX);
	float dirX = lD - lB;
	dir.x += dirX * w;
	lenX = saturate(abs(dirX) * lenX);
	lenX *= lenX;
	len += lenX * w;
	// Repeat for the y axis.
	float ec = lE - lC;
	float ca = lC - lA;
	float lenY = max(abs(ec), abs(ca));
	lenY = rcp(lenY);
	float dirY = lE - lA;
	dir.y += dirY * w;
	lenY = saturate(abs(dirY) * lenY);
	lenY *= lenY;
	len += lenY * w;
}


MAGPIE_ENTRY(main) {
	InitMagpieSampleInput();

	//------------------------------------------------------------------------------------------------------------------------------
	  // Get position of 'f'.
	float2 pp = (floor(Coord(0).xy / Coord(0).zw) + 0.5) * srcSize * rcp(destSize) - 0.5;
	float2 fp = floor(pp);
	pp -= fp;
	//------------------------------------------------------------------------------------------------------------------------------
	  // 12-tap kernel.
	  //    b c
	  //  e f g h
	  //  i j k l
	  //    n o
	  // Gather 4 ordering.
	  //  a b
	  //  r g
	  // For packed FP16, need either {rg} or {ab} so using the following setup for gather in all versions,
	  //    a b    <- unused (z)
	  //    r g
	  //  a b a b
	  //  r g r g
	  //    a b
	  //    r g    <- unused (z)
	  // Allowing dead-code removal to remove the 'z's.
	float2 p0 = fp + float2(1, -1);
	// These are from p0 to avoid pulling two constants on pre-Navi hardware.
	float2 p1 = p0 + float2(-1, 2);
	float2 p2 = p0 + float2(1, 2);
	float2 p3 = p0 + float2(0, 4);

	p0 = GetCheckedPos(0, p0 * Coord(0).zw);
	p1 = GetCheckedPos(0, p1 * Coord(0).zw);
	p2 = GetCheckedPos(0, p2 * Coord(0).zw);
	p3 = GetCheckedPos(0, p3 * Coord(0).zw);

	float4 bczzR = GatherInputRed(0, p0);
	float4 bczzG = GatherInputGreen(0, p0);
	float4 bczzB = GatherInputBlue(0, p0);
	float4 ijfeR = GatherInputRed(0, p1);
	float4 ijfeG = GatherInputGreen(0, p1);
	float4 ijfeB = GatherInputBlue(0, p1);
	float4 klhgR = GatherInputRed(0, p2);
	float4 klhgG = GatherInputGreen(0, p2);
	float4 klhgB = GatherInputBlue(0, p2);
	float4 zzonR = GatherInputRed(0, p3);
	float4 zzonG = GatherInputGreen(0, p3);
	float4 zzonB = GatherInputBlue(0, p3);
	//------------------------------------------------------------------------------------------------------------------------------
	  // Simplest multi-channel approximate luma possible (luma times 2, in 2 FMA/MAD).
	float4 bczzL = bczzB * 0.5 + (bczzR * 0.5 + bczzG);
	float4 ijfeL = ijfeB * 0.5 + (ijfeR * 0.5 + ijfeG);
	float4 klhgL = klhgB * 0.5 + (klhgR * 0.5 + klhgG);
	float4 zzonL = zzonB * 0.5 + (zzonR * 0.5 + zzonG);
	// Rename.
	float bL = bczzL.x;
	float cL = bczzL.y;
	float iL = ijfeL.x;
	float jL = ijfeL.y;
	float fL = ijfeL.z;
	float eL = ijfeL.w;
	float kL = klhgL.x;
	float lL = klhgL.y;
	float hL = klhgL.z;
	float gL = klhgL.w;
	float oL = zzonL.z;
	float nL = zzonL.w;
	// Accumulate for bilinear interpolation.
	float2 dir = 0;
	float len = 0;
	FsrEasuSet(dir, len, pp, true, false, false, false, bL, eL, fL, gL, jL);
	FsrEasuSet(dir, len, pp, false, true, false, false, cL, fL, gL, hL, kL);
	FsrEasuSet(dir, len, pp, false, false, true, false, fL, iL, jL, kL, nL);
	FsrEasuSet(dir, len, pp, false, false, false, true, gL, jL, kL, lL, oL);
	//------------------------------------------------------------------------------------------------------------------------------
	  // Normalize with approximation, and cleanup close to zero.
	float2 dir2 = dir * dir;
	float dirR = dir2.x + dir2.y;
	bool zro = dirR < 1.0f / 32768.0f;
	dirR = rsqrt(dirR);
	dirR = zro ? 1 : dirR;
	dir.x = zro ? 1 : dir.x;
	dir *= dirR;
	// Transform from {0 to 2} to {0 to 1} range, and shape with square.
	len = len * 0.5;
	len *= len;
	// Stretch kernel {1.0 vert|horz, to sqrt(2.0) on diagonal}.
	float stretch = (dir.x * dir.x + dir.y * dir.y) * rcp(max(abs(dir.x), abs(dir.y)));
	// Anisotropic length after rotation,
	//  x := 1.0 lerp to 'stretch' on edges
	//  y := 1.0 lerp to 2x on edges
	float2 len2 = { 1 + (stretch - 1) * len, 1 - 0.5 * len };
	// Based on the amount of 'edge',
	// the window shifts from +/-{sqrt(2.0) to slightly beyond 2.0}.
	float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
	// Set distance^2 clipping point to the end of the adjustable window.
	float clp = rcp(lob);
	//------------------------------------------------------------------------------------------------------------------------------
	  // Accumulation mixed with min/max of 4 nearest.
	  //    b c
	  //  e f g h
	  //  i j k l
	  //    n o
	float3 min4 = min(min3(float3(ijfeR.z, ijfeG.z, ijfeB.z), float3(klhgR.w, klhgG.w, klhgB.w), float3(ijfeR.y, ijfeG.y, ijfeB.y)),
		float3(klhgR.x, klhgG.x, klhgB.x));
	float3 max4 = max(max3(float3(ijfeR.z, ijfeG.z, ijfeB.z), float3(klhgR.w, klhgG.w, klhgB.w), float3(ijfeR.y, ijfeG.y, ijfeB.y)),
		float3(klhgR.x, klhgG.x, klhgB.x));
	// Accumulation.
	float3 aC = 0;
	float aW = 0;
	FsrEasuTap(aC, aW, float2(0.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x)); // b
	FsrEasuTap(aC, aW, float2(1.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y)); // c
	FsrEasuTap(aC, aW, float2(-1.0, 1.0) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
	FsrEasuTap(aC, aW, float2(0.0, 1.0) - pp, dir, len2, lob, clp, float3(ijfeR.y, ijfeG.y, ijfeB.y)); // j
	FsrEasuTap(aC, aW, float2(0.0, 0.0) - pp, dir, len2, lob, clp, float3(ijfeR.z, ijfeG.z, ijfeB.z)); // f
	FsrEasuTap(aC, aW, float2(-1.0, 0.0) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
	FsrEasuTap(aC, aW, float2(1.0, 1.0) - pp, dir, len2, lob, clp, float3(klhgR.x, klhgG.x, klhgB.x)); // k
	FsrEasuTap(aC, aW, float2(2.0, 1.0) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y)); // l
	FsrEasuTap(aC, aW, float2(2.0, 0.0) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z)); // h
	FsrEasuTap(aC, aW, float2(1.0, 0.0) - pp, dir, len2, lob, clp, float3(klhgR.w, klhgG.w, klhgB.w)); // g
	FsrEasuTap(aC, aW, float2(1.0, 2.0) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z)); // o
	FsrEasuTap(aC, aW, float2(0.0, 2.0) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w)); // n
  //------------------------------------------------------------------------------------------------------------------------------
	// Normalize and dering.
	float3 c = min(max4, max(min4, aC * rcp(aW)));

	return float4(c, 1.0f);
}