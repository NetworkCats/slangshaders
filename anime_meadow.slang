// anime_meadow.slang
//
// A Shinkai-style summer meadow rendered "3D as 2D", composed after
// the reference painting: a deep ultramarine sky over a band of towering cumulus,
// a bright hazy meadow with a gentle rise and a bush on the left, and a foreground
// of teal grass. Fixed camera; clouds drift and slowly churn, their shadows slide
// over the field, and the grass sways in a light breeze.
//
// Lighting is linear HDR with one sun, the sky dome and ray-traced bounce light:
//   * clouds are volumes, ray-marched per cloud: Beer transmittance toward the sun,
//     multiple-scattering octaves, dual-lobe phase, powder, occluded sky/ground
//     ambient. Each cloud forms, grows its towers and evaporates; turrets rise,
//     swell and evaporate; torn fractus drift beside the towers. A gentle grade
//     firms the physical light into white crowns and blue shade
//   * the meadow and grass receive drifting cloud shadows, canopy self-shadowing,
//     ambient occlusion and translucency
//   * the field is a heightfield in metres (a grassy bank in front, a swale, the
//     rise the barn stands on, low hills), ray-traced from a 4 m eye; a disused
//     railway yard stands on it: track and buffer stops, utility poles and wires,
//     sheds, a barn, a footbridge station and shrubs (see Railway yard)
//   * global illumination: the structures gather one-bounce light with
//     cosine-weighted rays traced against their distance fields, the terrain
//     heightfield and the sky dome (sunlit meadow, sunlit walls, sky); glass,
//     steel and worn rail heads trace a Fresnel-weighted mirror ray; the field
//     traces rays for the sky the structures and the land hide from it and the
//     light their sunlit faces send back; sun shadows are traced soft shadows
//   * light is set like a painting: the sky bright, the land under it lower in
//     key, a big cloud overhead shading the near field while sun falls in
//     patches on the middle distance
//   * aerial perspective blends distance into a warm, light-filled haze
// The hand-painted look: light firmed into painted planes with a brushed
// terminator and folded into soft half-stop value steps, laid in with short
// flat brush dabs of constant size on screen; textures are posterized patches
// and broad washes rather than fine noise, and drawn detail (board joints,
// corrugations) thins out where it would crowd on screen; line art drawn
// where a wide normal departs from the surface's (dark lines in creases, light
// lines on sunlit edges) and on silhouettes, then a warm grade with a gentle
// S-curve over ACES.
//
// Camera: shot as on 35 mm motion-picture film through a vintage spherical cine
// prime (see Camera: lens and film) - a 26 mm lens on a Super 35 gate sets the
// field of view; the lens adds a slight barrel distortion, lateral colour
// fringing, cos^4 vignetting and a soft veiling glare; the film adds red
// halation round the highlights, a gently faded vintage colour, exposure-
// dependent colour grain, and from frame to frame gate weave and flicker.
//
// Entry points:
//   computeMain               - pass 1: the scene, linear HDR, into gOutput
//                               (RWTexture2D, float; alpha holds the highlights)
//   postMain                  - pass 2: lens and film; reads pass 1 as gInput
//                               (mip-mapped, sampled with gSampler) and writes
//                               the final sRGB picture into gOutput
//   vertexMain / fragmentMain - single-pass raster path: the scene, the lens's
//                               vignette and the film (no fringing, distortion,
//                               glare or halation, which need the neighbours)
// All read gScene { resolution, time }.

struct SceneParams
{
    float2 resolution;
    float  time;
    float  _pad;
};

ConstantBuffer<SceneParams> gScene;
RWTexture2D<float4>         gOutput;
Texture2D<float4>           gInput;     // postMain: the scene from computeMain, with mips
SamplerState                gSampler;   // postMain: bilinear, trilinear between mips, clamped

// ---------------------------------------------------------------------------
// Scene constants (screen space: y up, height 1, x in [0, aspect])
// ---------------------------------------------------------------------------

static const float PI      = 3.14159265;
static const float HORIZON = 0.25;
static const float FOCAL   = 0.30;   // pseudo-perspective for the meadow

// Sun high on the right. z+ points at the camera. The clouds sit far off on the
// horizon, so in their own frame the sun is behind and to the right of them
// (bright crowns, blue shaded faces); the nearby land is lit from the front-right.
float3 sunDir()      { return normalize(float3(0.74, 0.46, -0.48)); }
float3 sunDirLand()  { return normalize(float3(0.62, 0.62, 0.40)); }

static const float3 SUN       = float3(1.00, 0.94, 0.80) * 2.75;
static const float3 SKY_AMB   = float3(0.14, 0.36, 0.86) * 0.80;  // light from the blue sky dome
static const float3 GROUND_BOUNCE = float3(0.30, 0.42, 0.14) * 0.35;
static const float3 HAZE      = float3(0.56, 0.78, 1.00);          // horizon inscatter (sky)
static const float3 LAND_HAZE = float3(0.78, 0.86, 0.74);          // sunlit air over the land: pale, warm

// ---------------------------------------------------------------------------
// Hash / noise
// ---------------------------------------------------------------------------

float hash11(float p)
{
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash12(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float hash13(float3 p3)
{
    p3 = frac(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

float vnoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash12(i);
    float b = hash12(i + float2(1, 0));
    float c = hash12(i + float2(0, 1));
    float d = hash12(i + float2(1, 1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float vnoise3(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i);
    float n100 = hash13(i + float3(1, 0, 0));
    float n010 = hash13(i + float3(0, 1, 0));
    float n110 = hash13(i + float3(1, 1, 0));
    float n001 = hash13(i + float3(0, 0, 1));
    float n101 = hash13(i + float3(1, 0, 1));
    float n011 = hash13(i + float3(0, 1, 1));
    float n111 = hash13(i + float3(1, 1, 1));
    return lerp(lerp(lerp(n000, n100, u.x), lerp(n010, n110, u.x), u.y),
                lerp(lerp(n001, n101, u.x), lerp(n011, n111, u.x), u.y), u.z);
}

// Rotated-octave fBm, normalised to roughly [0, 1].
float fbm(float2 p, int octaves)
{
    float sum = 0.0;
    float amp = 0.5;
    float norm = 0.0;
    for (int i = 0; i < octaves; i++)
    {
        sum += amp * vnoise(p);
        norm += amp;
        p = float2(p.x * 1.6 - p.y * 1.2, p.x * 1.2 + p.y * 1.6) + 17.13;
        amp *= 0.5;
    }
    return sum / norm;
}

float fbm3(float3 p, int octaves)
{
    float sum = 0.0;
    float amp = 0.5;
    float norm = 0.0;
    for (int i = 0; i < octaves; i++)
    {
        sum += amp * vnoise3(p);
        norm += amp;
        p = float3(p.y * 1.62 + p.z * 0.6, p.z * 1.62 - p.x * 0.6, p.x * 1.62 + p.y * 0.6) * 1.18 + 11.7;
        amp *= 0.5;
    }
    return sum / norm;
}

// Billowy (inverted ridge) fBm: rounded heaps with creases between them.
float billow3(float3 p, int octaves)
{
    float n = fbm3(p, octaves);
    return 1.0 - abs(n * 2.0 - 1.0);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

float celStep(float edge, float width, float x) { return smoothstep(edge - width, edge + width, x); }

float sq(float x) { return x * x; }

// Henyey-Greenstein phase function.
float phaseHG(float mu, float g)
{
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * mu, 1e-4), 1.5));
}

// Painted texture: soft short strokes laid along `dir` (unit), roughly 0..1.
float brush(float2 uv, float2 dir)
{
    float2 q = float2(dot(uv, dir), dot(uv, float2(-dir.y, dir.x)));
    return vnoise(q * float2(1.0, 5.0)) * 0.6 + vnoise(q * float2(2.1, 11.0) + 5.1) * 0.4;
}

// Noise folded into a few flat values with soft steps between them: painted
// patches instead of a continuous (photographic) texture.
float posterize(float x, float steps)
{
    float y = x * steps;
    return (floor(y) + smoothstep(0.3, 0.7, frac(y))) / steps;
}

// Dabs of paint of a constant size on screen: short flat strokes laid along
// `dir` (unit) in staggered rows, their edges wavering; each stroke's value
// (0..1). sp is in pixels of a 1080-line frame, so a stroke is a few pixels.
float paintDabs(float2 sp, float2 dir)
{
    float2 q = float2(dot(sp, dir), dot(sp, float2(-dir.y, dir.x)));
    q += (float2(vnoise(sp * 0.30), vnoise(sp * 0.30 + 7.7)) - 0.5) * 2.0;
    q /= float2(13.0, 3.6);
    float row = floor(q.y);
    q.x += hash11(row * 3.1) * 7.0;
    float2 id = float2(floor(q.x), row);
    float f = frac(q.x);
    return lerp(hash12(id), hash12(id + float2(1.0, 0.0)), smoothstep(0.82, 1.0, f) * 0.5);
}

float smin(float a, float b, float k)
{
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

// Breeze strength 0..1; gusts roll across the field from left to right.
float windField(float x, float t)
{
    float g = 0.55 + 0.45 * sin(x * 0.9 - t * 0.55);
    g *= 0.70 + 0.30 * sin(x * 2.3 - t * 1.10 + 1.3);
    g += 0.25 * (vnoise(float2(x * 1.7 - t * 0.6, t * 0.07)) - 0.5);
    return saturate(g);
}

// Drifting cloud-shadow visibility on the meadow (1 = sunlit), in pseudo ground coords.
float cloudShadow(float2 ground, float t)
{
    float2 q = ground * float2(0.050, 0.10) + float2(-t * 0.012, 0.0);
    float n = fbm(q + float2(3.7, 1.9), 5);
    return lerp(1.0, 0.30, smoothstep(0.58, 0.68, n));
}

// Aerial perspective toward the bright horizon haze.
float3 applyHaze(float3 c, float amount)
{
    return lerp(c, LAND_HAZE, saturate(amount));
}

// ---------------------------------------------------------------------------
// Sky
// ---------------------------------------------------------------------------

float3 skyColor(float2 p, float aspect, float t)
{
    float h = saturate((p.y - HORIZON) / (1.0 - HORIZON));
    // Deep ultramarine overhead, clear azure lower down, milky cyan at the horizon.
    float3 zenith  = float3(0.008, 0.052, 0.180);
    float3 upper   = float3(0.046, 0.150, 0.460);
    float3 lower   = float3(0.165, 0.420, 1.120);
    float3 horizon = float3(0.380, 0.700, 1.120);
    float3 sky = lerp(lower, upper, smoothstep(0.18, 0.62, h));
    sky = lerp(sky, zenith, smoothstep(0.55, 1.0, h));
    sky = lerp(horizon, sky, smoothstep(0.0, 0.28, h));
    // Mie aureole from the sun just beyond the upper-right corner: the sky lightens
    // and turns a touch cyan toward it, and is deepest on the opposite side.
    float sunD = length(p - float2(aspect * 1.08, 1.12));
    float aureole = exp(-sunD * 1.5);
    sky = sky * (0.90 + 0.10 * smoothstep(0.0, 1.0, p.x / aspect)) + float3(0.16, 0.30, 0.40) * aureole * 0.32;
    // Faint painted unevenness.
    sky *= 0.97 + 0.06 * fbm(float2(p.x * 1.2 + t * 0.002, p.y * 3.0), 3);
    return sky;
}

// ---------------------------------------------------------------------------
// Volumetric cumulus congestus
//
// Each cloud is a cluster of rising thermals seen far off over the horizon.
// It lives in its own space in units of H (screen height of its tallest tower):
// x across the screen, y up from a flat condensation base, z toward the camera.
//   * shape: a broad deck with several towers, each a column under a dome. Turrets
//     (thermal bubbles) push up out of the domes, swell and spread as they rise,
//     then evaporate, staggered so the cloud keeps growing new ones; the towers
//     themselves slowly build and slump. Small fractus shreds tear off the flanks;
//   * life: each cloud forms out of clear air, builds its towers, matures and
//     evaporates, and a different one forms in its place;
//   * placement: four bands of towering cumulus 65-150 km away, sized, raised and
//     drifted by a long-lens sky camera (30 degree fov, 1.2 km cloud base, Earth
//     curvature hides the bases), hazed by distance;
//   * density: inverted Worley noise at several scales carves cauliflower billows,
//     crisp on the rising crowns; warped fBm frays the lower body into wisps. The
//     noise rises with the updraft and a time-evolving turbulence field deforms
//     it, so the billows swell, merge and dissolve as the cloud drifts;
//   * light: optical depth marched toward the sun (Beer), multiple-scattering
//     octaves with a fading phase anisotropy (Wrenninge), a dual-lobe
//     Henyey-Greenstein phase, a powder term for the in-scattering that has not
//     built up near the surface, and sky / ground ambient attenuated by the cloud
//     above and below each sample; energy-conserving integration (Hillaire);
//   * march: the coarse distance field skips empty space, fine steps inside.
// ---------------------------------------------------------------------------

static const int TOWERS = 6;
static const int TURRETS = 4;                // per tower, staggered over the life cycle
static const float TURRET_LIFE = 150.0;      // seconds from a turret's birth to its evaporation
static const float CLOUD_LIFE = 600.0;       // seconds from a cloud's formation to its evaporation
static const float CLOUD_SIGMA = 70.0;       // extinction at density 1, per H
static const float CLOUD_SUN = 0.44;         // sun irradiance scale inside the cloud
static const float3 CLOUD_SKY = float3(0.08, 0.20, 0.47);     // skylight from the dome above
static const float3 CLOUD_GROUND = float3(0.12, 0.15, 0.08);  // meadow bounce from below

float3 hash33(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.xxy + p.yxx) * p.zyx);
}

// Squared Worley F1 distance, ~[0, 0.8].
float worley3sq(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    float md = 1.0;
    for (int z = -1; z <= 1; z++)
        for (int y = -1; y <= 1; y++)
            for (int x = -1; x <= 1; x++)
            {
                float3 o = float3(float(x), float(y), float(z));
                float3 r = o + hash33(i + o) - f;
                md = min(md, dot(r, r));
            }
    return md;
}

// Worley F1 distance, ~[0, 1].
float worley3(float3 p) { return sqrt(worley3sq(p)); }

// Cauliflower billow, zero mean: the squared distance is parabolic around each
// feature point, so the bulges are round domes with sharp creases between them
// (plain F1 is linear there and grows cones).
float billow(float3 p) { return (worley3sq(p) - 0.20) * 1.5; }

// Ellipsoid distance approximation (Quilez).
float sdEllipsoid(float3 p, float3 r)
{
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-5);
}

// Thermal i: footprint centre (x, z), radius, top height. Thermal 0 is the tallest.
float4 towerParams(float seed, int i, float halfW, out float z)
{
    float fi = float(i);
    float h1 = hash11(seed * 3.17 + fi * 1.31);
    float h2 = hash11(seed * 7.73 + fi * 2.11);
    float h3 = hash11(seed * 1.93 + fi * 5.37);
    float h4 = hash11(seed * 5.51 + fi * 3.99);
    if (i == 0)
    {
        z = 0.0;
        return float4((h1 - 0.5) * 0.35 * halfW, 0.0, 0.46 + 0.08 * h2, 1.0);
    }
    float side = (i % 2 == 0) ? 1.0 : -1.0;
    float x = side * lerp(0.20, 0.85, h1) * halfW;
    float edge = abs(x) / max(halfW, 1e-3);
    float top = lerp(0.38, 0.88, h4) * (1.0 - 0.50 * edge);
    z = (h3 - 0.5) * 0.55;
    return float4(x, 0.0, lerp(0.26, 0.38, h2) + 0.16 * top, top);
}

float fi3(int i, int k) { return float(i) * 7.13 + float(k) * 3.31; }

// One cloud: its shape seed, half width (units of H), time, how soft its base is
// (small far clouds), and where it is in its life: `grow` 0..1 as the towers build
// up, `fade` 0..1 as it forms out of / evaporates into clear air.
struct Cloud
{
    float seed;
    float halfW;
    float t;
    float baseSoft;
    float grow;
    float fade;
    float wisps;   // 0..1: fractus only show on clouds big enough on screen
};

// Coarse signed distance (negative inside), in units of H.
float cloudShape(float3 q, Cloud cl)
{
    float seed = cl.seed;
    float halfW = cl.halfW;
    float t = cl.t;
    // Wind shear: the upper parts drift downwind.
    q.x -= 0.05 * q.y * q.y;
    q.x += 0.025 * sin(q.y * 6.0 + seed * 2.3);
    float d = sdEllipsoid(q, float3(halfW * 0.95, 0.24, 0.62));
    for (int i = 0; i < TOWERS; i++)
    {
        float tz;
        float4 tw = towerParams(seed, i, halfW, tz);
        float R = tw.z;
        // Towers build up as the cloud grows (the side ones later than the main
        // one), then slowly build and slump as their updrafts strengthen and fade.
        float g = saturate(cl.grow * 1.25 - 0.25 * float(i) / float(TOWERS));
        float H = tw.w * lerp(0.35, 1.0, g) * (0.94 + 0.06 * sin(t * 0.007 + seed * 1.7 + float(i) * 2.1));
        float jx = (hash11(seed + fi3(i, 1)) - 0.5) * 0.25 * R;
        float stem = sdEllipsoid(q - float3(tw.x, 0.0, tz), float3(R * 1.10, H * 0.78, R * 0.95));
        float cap = sdEllipsoid(q - float3(tw.x + jx, H * 0.70, tz), float3(R * 0.82, H * 0.30, R * 0.76));
        float th = smin(stem, cap, 0.05);
        // Turrets: a bubble pushes up through the dome, swells and spreads as it
        // rises, then loses its buoyancy and evaporates back into the tower.
        // Each turret is new: its size, place and pace are drawn afresh every cycle
        // (the switch happens while it is gone), so the towers never repeat.
        float h0 = hash11(seed + fi3(i, 3));
        float life0 = TURRET_LIFE * lerp(0.75, 1.30, hash11(seed + fi3(i, 11)));
        for (int k = 0; k < TURRETS; k++)
        {
            float cyc = t / life0 + h0 + float(k) / float(TURRETS);
            float ph = frac(cyc);
            float hc = floor(cyc) * 1.618 + fi3(i, 4 + k);
            float side = hash11(seed + hc) * 2.0 - 1.0;
            float size = lerp(0.75, 1.25, hash11(seed + hc + 0.37));
            float life = smoothstep(0.0, 0.30, ph) * (1.0 - smoothstep(0.62, 1.0, ph));
            float r = R * lerp(0.36, 0.56, ph) * size * life + 1e-3;
            float3 c = float3(tw.x + jx + side * R * lerp(0.20, 0.55, ph),
                              H * lerp(0.62, 1.0, ph),
                              tz + (hash11(seed + hc + 0.71) - 0.5) * R * 0.7);
            float b = sdEllipsoid(q - c, float3(r, r * 0.82, r * 0.95)) + 0.06 * (1.0 - life);
            th = smin(th, b, 0.05);
        }
        d = smin(d, th, 0.05);
    }
    return max(d, -q.y);  // flat base
}

// Density at q given its coarse distance d.
float cloudDensityAt(float3 q, float d, Cloud cl, int detail)
{
    if (d > 0.30) return 0.0;
    float seed = cl.seed;
    float t = cl.t;
    float baseSoft = cl.baseSoft;
    float hgt = saturate(q.y);
    // Motion. The billows rise slowly with the updraft, and a turbulence field that
    // evolves in time (not just scrolls) deforms them, so they swell, merge and
    // dissolve. The rise is uniform: a height-dependent speed would shear the noise
    // further every second and smear it into streaks.
    float3 f = q + seed * 1.37;
    float rise = t * 0.0032;
    float3 tq = f * 1.4 + float3(0.0, -rise, 0.0);
    float3 turb = float3(fbm3(tq + float3(0.0, 0.0, t * 0.0075), 2),
                         fbm3(tq + float3(5.2, 1.3, -t * 0.0060), 2),
                         fbm3(tq + float3(2.7, 8.1, t * 0.0068), 2)) - 0.5;
    f += turb * 0.12 + float3(-t * 0.0015, -rise, 0.0);
    // Cauliflower: inverted Worley bulges, strongest on the rising crowns.
    float crown = 0.75 + 0.6 * hgt;
    d += billow(f * 2.0 + 9.0) * 0.13 * crown;
    d += billow(f * 4.3) * 0.075 * crown + (fbm3(f * 2.2 + 4.0, 2) - 0.5) * 0.10;
    float3 fw = f;
    if (detail > 0)
    {
        // Turbulent warp of the fine detail: it curls into wisps, most strongly low
        // on the cloud where real cumulus edges evaporate.
        float3 wv = float3(fbm3(f * 5.0 + 1.7, 2), fbm3(f * 5.0 + 9.1, 2), fbm3(f * 5.0 + 4.3, 2)) - 0.5;
        fw = f + wv * lerp(0.11, 0.025, hgt);
        d += billow(fw * 9.0 + 3.1) * 0.036 * crown;
        d += (fbm3(fw * 20.0, 2) - 0.5) * 0.040 * (1.3 - hgt);
    }
    if (detail > 1)
    {
        d += billow(fw * 19.0 + 7.7) * 0.015 * crown;
        d += billow(fw * 38.0 + 1.3) * 0.006 * crown;
    }
    if (detail > 0)
    {
        // Frayed skin: torn wisps on the flanks and base, fine bumps on the crowns.
        float skin = smoothstep(-0.05, 0.05, d);
        d += (fbm3(fw * 12.0 + 2.2, 3) - 0.5) * 0.08 * skin * lerp(1.6, 0.6, hgt);
    }
    // Small clouds round off underneath: the body pulls in toward the base.
    d += baseSoft * 0.09 * (1.0 - smoothstep(0.0, 0.40, q.y + (fbm3(fw * 7.0 + 1.1, 2) - 0.5) * 0.25));
    // A forming or dying cloud is thin: it evaporates from the edges inward.
    d += cl.fade * 0.22;
    // Crisp, well-defined crowns; soft, thinning vapour lower down.
    float dens = saturate(-d * lerp(9.0, 30.0, smoothstep(0.08, 0.55, hgt)));
    // Condensation level: a flat, slightly uneven base (the lifting condensation
    // level); small clouds dissolve underneath instead.
    dens *= smoothstep(0.0, lerp(0.07, 0.60, baseSoft), q.y + (fbm3(fw * 9.0 + 3.3, 2) - 0.5) * lerp(0.06, 0.30, baseSoft));
    return dens * (1.0 - cl.fade * cl.fade);
}

// Fractus: small torn shreds drifting beside the towers, each a thin flattened
// puff frayed by stretched noise. Each one forms, slides downwind relative to the
// cloud (the wind is stronger aloft) and evaporates, then reappears elsewhere.
// Returns the density; `dist` is a lower bound on the distance to any shred.
static const int WISPS = 6;
static const float WISP_LIFE = 70.0;

float wispDensity(float3 q, Cloud cl, float dMain, out float dist)
{
    dist = 1e3;
    float dens = 0.0;
    float g = lerp(0.35, 1.0, cl.grow);
    for (int w = 0; w < WISPS; w++)
    {
        float fw = float(w);
        float cyc = cl.t / (WISP_LIFE * lerp(0.8, 1.3, hash11(cl.seed * 2.3 + fw))) + hash11(cl.seed + fw * 4.7);
        float ph = frac(cyc);
        float hc = cl.seed * 1.91 + fw * 6.13 + floor(cyc) * 3.07;
        float rx = lerp(0.06, 0.15, hash11(hc + 0.1));
        // Torn off the flank of one of the towers, part way up.
        float tz;
        float4 tw = towerParams(cl.seed, int(hash11(hc + 0.2) * float(TOWERS) * 0.999), cl.halfW, tz);
        float side = hash11(hc + 0.5) < 0.5 ? -1.0 : 1.0;
        float3 c = float3(tw.x + side * (tw.z * 1.25 + rx * 0.6) + (ph - 0.4) * 0.25,
                          tw.w * g * lerp(0.35, 0.80, hash11(hc + 0.3)),
                          tz + (hash11(hc + 0.4) - 0.5) * 0.5);
        float3 r = float3(rx, rx * 0.32, rx * 0.6);
        float d = sdEllipsoid(q - c, r);
        dist = min(dist, d);
        if (d > 0.05) continue;
        float life = smoothstep(0.0, 0.35, ph) * (1.0 - smoothstep(0.55, 1.0, ph)) * smoothstep(0.5, 0.9, cl.grow);
        // Small ragged puffs (the towers' billows at a finer scale), torn apart by
        // noise stretched along the wind; they erode away as they age.
        float3 lq = (q - c) + hc * 0.37;
        float dd = d + billow(lq * 16.0) * 0.035
                 + (fbm3(lq * float3(7.0, 20.0, 10.0) + float3(-cl.t * 0.02, 0.0, cl.t * 0.01), 3) - 0.5) * 0.09
                 + (1.0 - life) * 0.04;
        dens += saturate(-dd * 22.0) * 0.85 * smoothstep(0.0, 0.3, life);
    }
    // Shreds live in the clear air beside the towers, not inside them.
    return saturate(dens) * smoothstep(0.02, 0.15, dMain) * (1.0 - cl.fade * cl.fade) * cl.wisps;
}

float cloudDensity(float3 q, Cloud cl, int detail)
{
    float dw;
    float d = cloudShape(q, cl);
    return saturate(cloudDensityAt(q, d, cl, detail) + wispDensity(q, cl, d, dw));
}

// Dual-lobe phase, normalised so isotropic scattering is 1: a strong forward lobe
// (the silver lining toward the sun) and a weak back-scatter lobe. `g` scales the
// anisotropy down for the higher scattering orders.
float cloudPhase(float mu, float g)
{
    return lerp(phaseHG(mu, 0.80 * g), phaseHG(mu, -0.20 * g), 0.30) * 4.0 * PI;
}

// Gentle anime grade over the physical result, matching the rest of the scene:
// the physical sunlight decides where the light falls, a soft ramp firms it into
// broad tones - white crowns, a cool half-tone at the terminator, blue shade and
// darker crevices (the skylight decides which) - blended half-way with the
// physical shading so the cloud stays soft and volumetric.
static const float  CLOUD_STYLE = 0.78;
static const float3 PAINT_HI    = float3(1.30, 1.25, 1.10);   // sun-struck crowns, warm white
static const float3 PAINT_LIT   = float3(0.84, 0.87, 0.88);   // lit body
static const float3 PAINT_HALF  = float3(0.42, 0.67, 0.86);   // terminator half-tone, pale cyan
static const float3 PAINT_SHADE = float3(0.06, 0.25, 0.50);  // cyan-teal shade
static const float3 PAINT_DEEP  = float3(0.025, 0.11, 0.27); // crevices

float3 cloudPaint(float3 phys, float3 sunC, float3 ambC)
{
    float s = luminance(sunC) / (luminance(SUN) * CLOUD_SUN);
    float av = luminance(ambC) / luminance(CLOUD_SKY);
    float3 shade = lerp(PAINT_DEEP, PAINT_SHADE, smoothstep(0.20, 0.85, av));
    float3 paint = lerp(shade, PAINT_HALF, smoothstep(0.06, 0.16, s));
    paint = lerp(paint, PAINT_LIT, smoothstep(0.17, 0.30, s));
    paint = lerp(paint, PAINT_HI, smoothstep(0.42, 0.80, s));
    // Keep the billows' own modelling inside the broad tones (above all in the
    // light, which would otherwise be one flat white).
    float form = luminance(phys) / max(luminance(paint), 1e-3);
    paint *= lerp(1.0, clamp(form, 0.70, 1.25), 0.40);
    return lerp(phys, paint, CLOUD_STYLE);
}

// Ray-march one cloud and composite it over `col`.
//   base: screen position of the base centre, H: screen height of its tallest tower,
//   halfW: half width in units of H, haze: aerial perspective (0 = near)
void drawCloud(inout float3 col, float2 p, float2 base, float H, float halfW, float seed,
               float haze, float3 air, float t, float px, float grow, float fade)
{
    float2 q2 = (p - base) / H;
    if (q2.y < -0.02 || q2.y > 1.45 || abs(q2.x) > halfW + 0.9 || fade >= 1.0) return;
    Cloud cl;
    cl.seed = seed;
    cl.halfW = halfW;
    cl.t = t;
    cl.baseSoft = 1.0 - smoothstep(0.03, 0.08, H);
    cl.grow = grow;
    cl.fade = fade;
    cl.wisps = smoothstep(0.12, 0.16, H);

    // Glow around the sunlit cloud: humid air scatters its light forward, and the
    // halo leans toward the sun side.
    float dOut = min(min(cloudShape(float3(q2, -0.25), cl), cloudShape(float3(q2, 0.0), cl)),
                     cloudShape(float3(q2, 0.25), cl));
    {
        float2 toCloud = q2 - float2(0.0, 0.5);
        float sunSide = 0.45 + 0.55 * saturate(dot(normalize(toCloud + 1e-4), normalize(sunDir().xy)));
        float glow = exp(-max(dOut + 0.06, 0.0) * 8.0) * sunSide * smoothstep(0.05, 0.45, q2.y) * (1.0 - haze);
        col += SUN * float3(1.0, 0.97, 0.92) * 0.030 * glow;
    }

    // The whole cloud lies within |z| < 1.3 (deck, towers and noise); empty space
    // is skipped with the distance field, so a loose bound costs little.
    const float zF = 1.3;
    const float zB = -1.3;

    float3 L = sunDir();
    float mu = dot(float3(0.0, 0.0, -1.0), L);
    float ph[4];
    for (int n = 0; n < 4; n++) ph[n] = cloudPhase(mu, pow(0.5, float(n)));
    // Fine steps scale with the cloud's size on screen (a few px at most).
    float fine = clamp(2.5 * px / H, 0.005, 0.012);
    // Static per-pixel jitter (white noise, which supersampling averages out; a
    // structured pattern would print as streaks without TAA).
    float jitter = hash12(p / px + seed * 17.0);
    int detail = H > 0.10 ? 2 : 1;
    float T = 1.0;
    float3 accSun = float3(0, 0, 0);
    float3 accAmb = float3(0, 0, 0);
    float z = zF - jitter * fine;

    for (int i = 0; i < 320 && z > zB; i++)
    {
        float3 q = float3(q2, z);
        float ds = cloudShape(q, cl);
        float dw;
        float wd = wispDensity(q, cl, ds, dw);
        // Empty space: skip ahead by the coarse distance (conservatively, since the
        // shear and the ellipsoid approximation stretch it).
        // The landing point is re-jittered, or neighbouring rays would sample the
        // density shells in lockstep and print contour rings.
        if (ds > 0.30 && dw > 0.04)
        {
            z -= max(min((ds - 0.28) * 0.8, (dw - 0.02) * 0.8), fine) + jitter * fine;
            continue;
        }
        float dens = saturate(cloudDensityAt(q, ds, cl, detail) + wd);
        if (dens <= 0.002) { z -= fine * 2.5; continue; }  // eroded gaps

        float hgt = saturate(q.y);
        // Optical depth toward the sun: short first steps resolve each billow's own
        // shadow, longer ones the tower's.
        float od = 0.0;
        float stepL = 0.012;
        float dist = 0.0;
        float jl = frac(jitter + float(i) * 0.618034);
        for (int j = 0; j < 7; j++)
        {
            dist += stepL;
            od += cloudDensity(q + L * (dist - stepL * jl), cl, 0) * stepL;
            stepL *= 1.7;
        }
        // Multiple scattering (Wrenninge): each order travels further (less
        // extinction), contributes less and scatters more isotropically. Near the
        // surface the higher orders have not built up yet (powder), which darkens
        // the thin rims and creases between billows.
        float powder = 1.0 - exp(-dens * CLOUD_SIGMA * 0.04 - od * CLOUD_SIGMA * 0.35);
        float sunL = exp(-od * CLOUD_SIGMA) * ph[0];
        float a = 1.0;
        float b = 1.0;
        for (int n = 1; n < 4; n++)
        {
            a *= 0.40;
            b *= 0.32;
            sunL += a * exp(-od * CLOUD_SIGMA * b) * ph[n] * powder;
        }

        // Skylight and bounce from the meadow, each dimmed by the cloud in between
        // (diffuse light penetrates further than the direct beam). Skylight comes
        // from the dome above and the bright horizon in front: the tops of the
        // billows and the bulges facing us catch it, the crevices between them do
        // not, so the billows stay readable inside the shadow.
        float odUp = cloudDensity(q + float3(0.0, 0.018, 0.005), cl, 1) * 0.025
                   + cloudDensity(q + float3(0.0, 0.07, 0.02), cl, 0) * 0.07
                   + cloudDensity(q + float3(0.0, 0.25, 0.05), cl, 0) * 0.20;
        float odFr = cloudDensity(q + float3(0.0, 0.008, 0.02), cl, 1) * 0.025
                   + cloudDensity(q + float3(0.0, 0.03, 0.10), cl, 0) * 0.09;
        float odDn = cloudDensity(q - float3(0.0, 0.08, 0.0), cl, 0) * 0.10;
        float3 amb = CLOUD_SKY * (0.06 + 0.64 * exp(-odUp * CLOUD_SIGMA * 0.45) + 0.40 * exp(-odFr * CLOUD_SIGMA * 0.45))
                   + CLOUD_GROUND * exp(-odDn * CLOUD_SIGMA * 0.30) * (1.0 - 0.6 * smoothstep(0.0, 0.6, hgt));
        // Sunlight that reaches the base has crossed the cloud column above it
        // (the coarse march only sees the nearby billows), so the base is grey.
        float3 sunS = SUN * float3(1.0, 0.97, 0.91) * CLOUD_SUN * sunL * lerp(0.18, 1.0, smoothstep(0.02, 0.45, hgt));

        // Energy-conserving integration over the step (Hillaire 2015); sun and sky
        // light are kept apart for the painted grade.
        float stepZ = fine;
        float Ts = exp(-dens * CLOUD_SIGMA * stepZ);
        accSun += T * sunS * (1.0 - Ts);
        accAmb += T * amb * (1.0 - Ts);
        T *= Ts;
        if (T < 0.004) break;
        z -= stepZ;
    }

    float opacity = 1.0 - T;
    if (opacity <= 0.002) return;
    float3 c = cloudPaint((accSun + accAmb) / opacity, accSun / opacity, accAmb / opacity);
    // Aerial perspective: with distance the cloud fades into the sky behind it
    // (the air in between scatters the same light the sky shows), so far shade
    // turns a lighter blue rather than grey; the lower body a little more.
    float low = pow(1.0 - smoothstep(0.0, 0.25, q2.y), 1.8) * 0.08;
    c = lerp(c, air, saturate(haze + low * (1.0 - haze)));
    col = col * T + c * opacity;
}

// Slow drift with wrap-around; the composition repeats only after many minutes.
float driftX(float x0, float speed, float t, float aspect)
{
    float margin = 0.7;
    float period = aspect + 2.0 * margin;
    return fmod(fmod(x0 + speed * t + margin, period) + period, period) - margin;
}

// Sky camera. The clouds are placed in kilometres and projected: a cloud at
// distance D appears 1 / (D * SKY_TAN) screen heights per km, its flat base (the
// shared condensation level, lowered by the Earth's curvature) stands
// (base / D) / SKY_TAN above the horizon, and it drifts at wind / D. So farther
// clouds are smaller, sit lower, move slower and are paler with air.
static const float SKY_TAN    = GATE_H_MM / FOCAL_MM;   // 2 tan(fov / 2): 30.2 degrees vertical
static const float BASE_KM    = 1.2;     // cloud base altitude (humid summer air)
static const float EARTH_KM   = 6371.0;
static const float WIND_KMS   = 0.010;   // 10 m/s at cloud level
static const float VISIBILITY = 420.0;   // km, aerial-perspective scale (clean, clear air)
static const float CLOUD_TIME_SCALE = 0.6;  // pace of the clouds' growth and churn

float3 drawClouds(float3 col, float2 p, float aspect, float t, float px)
{
    // Four bands of cumulus at increasing distance, drawn back to front; the
    // farthest converge onto the horizon. Each band is an endless strip of clouds
    // at a regular spacing that drifts as a whole.
    float tc = t * CLOUD_TIME_SCALE;
    float3 air = skyColor(p, aspect, t);
    for (int layer = -2; layer < 2; layer++)
    {
        float fl = float(layer);
        float distKm  = layer < -1 ? 150.0 : (layer < 0 ? 110.0 : (layer == 0 ? 85.0 : 65.0));
        float kmToScr = 1.0 / (distKm * SKY_TAN);
        float speed   = WIND_KMS * kmToScr;
        float spacing = (layer < -1 ? 30.0 : (layer < 0 ? 26.0 : (layer == 0 ? 22.0 : 20.0))) * kmToScr;
        float baseY   = HORIZON + (BASE_KM - distKm * distKm / (2.0 * EARTH_KM)) / distKm / SKY_TAN;
        float haze    = 1.0 - exp(-distKm / VISIBILITY);
        float u = p.x - speed * t;
        float k0 = floor(u / spacing);
        for (int j = -2; j <= 2; j++)
        {
            float k = k0 + float(j);
            float r1 = hash11(k * 7.31 + fl * 101.7);
            // Life cycle: each cloud forms out of clear air, its towers build up, it
            // matures and finally evaporates; then a new, different cloud forms in
            // its place (the switch happens while the air is clear).
            float cyc = tc / CLOUD_LIFE * lerp(0.8, 1.25, hash11(k * 1.37 + fl * 9.1)) + hash11(k * 4.13 + fl * 71.3);
            float ph = frac(cyc);
            float kc = k + floor(cyc) * 113.0;
            float grow = smoothstep(0.0, 0.30, ph);
            float fade = max(1.0 - smoothstep(0.0, 0.08, ph), smoothstep(0.88, 1.0, ph));
            float r2 = hash11(kc * 3.17 + fl * 57.3);
            float r3 = hash11(kc * 5.93 + fl * 13.1);
            float r4 = hash11(kc * 8.29 + fl * 23.9);
            float cx = (k + 0.5 + (r1 - 0.5) * 0.35) * spacing + speed * t;
            // Tallest tower in km: towering cumulus congestus, 6-10 km tall, rising
            // far off over the horizon; their bases sink behind the Earth's curve.
            float topKm = layer < -1 ? lerp(4.0, 6.0, r2) : (layer < 0 ? lerp(5.0, 7.5, r2) : (layer == 0 ? lerp(6.5, 9.0, r2) : lerp(8.0, 11.0, r2)));
            float H     = topKm * kmToScr;
            float halfW = layer < -1 ? lerp(1.60, 2.20, r3) : (layer < 0 ? lerp(1.30, 1.80, r3) : (layer == 0 ? lerp(1.05, 1.45, r3) : lerp(0.95, 1.30, r3)));
            // Bases scatter a little around the condensation level.
            float by = baseY + (r4 - 0.5) * 0.12 * kmToScr;
            // Seeds come from a set of well-formed cloud shapes, varied per cell.
            float seed = floor(hash11(kc * 2.71 + fl * 33.3) * 5.0) + 1.0 + floor(hash11(kc * 7.31 + fl * 101.7) * 3.0) * 10.0;
            drawCloud(col, p, float2(cx, by), H, halfW, seed, haze, air, tc, px, grow, fade);
        }
    }
    return col;
}

// ---------------------------------------------------------------------------
// Land: the skyline, the meadow and the bush
// ---------------------------------------------------------------------------

// Height of the field in metres at world (x, z) (x right, z away from the eye):
// a low grassy bank in front of the eye, a shallow swale across the middle
// distance, gentle rolls, the rise the barn stands on, low hills on the skyline.
// Shadows of the cumulus overhead (1 = sunlit) at world (x, z) in metres: the
// footprints of the clouds - broad, ~250 m across and ~100 m deep, so in
// perspective they lie across the field as alternating bands of sun and shade -
// with soft edges where the cloud thins, drifting slowly downwind at 3 m/s. A cloud shadow is not black: the sky still lights
// it, so it reads as a cool, softer shade.
float cloudShadowW(float2 g, float t)
{
    t += 110.0;   // phase of the shadow pattern: sun on the middle distance in the opening frames
    float2 q = (g + float2(-t * 3.0, 0.0)) * float2(0.0040, 0.0100) + float2(8.2, 1.1);
    float n = fbm(q, 3) * 0.85 + fbm(q * 4.1 + 7.3, 2) * 0.15;   // rounded heads, softly frayed
    // A big cumulus stands overhead, just out of frame: its shadow lies over the
    // near field, and its ragged sunward edge wavers as it drifts, now and then
    // letting a patch of sun through.
    float edgeZ = 115.0 + 150.0 * (fbm(float2(g.x * 0.018 - t * 0.012, 3.3), 3) - 0.5);
    n += 0.20 * (1.0 - smoothstep(edgeZ - 60.0, edgeZ, g.y));
    return lerp(1.0, 0.30, smoothstep(0.515, 0.543, n));
}

float terrainH(float2 g)
{
    float x = g.x;
    float z = g.y;
    float h = 1.0 * (1.0 - smoothstep(6.0, 40.0, z)) * (1.0 + 0.25 * sin(x * 0.07 + 0.7));
    h -= 0.9 * exp(-sq((z - 60.0) / 26.0));
    h += 0.7 * sin(x * 0.031 + z * 0.010 + 1.1) * smoothstep(45.0, 110.0, z) * (1.0 - 0.75 * exp(-sq((z - 140.0) / 55.0)));
    h += 6.5 * exp(-sq((x + 32.0) / 52.0) - sq((z - 235.0) / 85.0));
    h += 3.0 * exp(-sq((x - 150.0) / 90.0) - sq((z - 330.0) / 120.0));
    h += smoothstep(320.0, 900.0, z) * (7.0 + 5.0 * sin(x * 0.0042 + 1.3) + 3.0 * sin(x * 0.0113 + 0.4));
    h += 0.25 * (vnoise(g * 0.045) - 0.5);
    return h;
}

float3 terrainNormal(float2 g)
{
    const float e = 0.6;
    float h0 = terrainH(g);
    return normalize(float3(h0 - terrainH(g + float2(e, 0.0)), e, h0 - terrainH(g + float2(0.0, e))));
}

// The meadow's procedural noise is laid out in "pseudo field" coordinates whose
// depth saturates toward the skyline (so distant noise does not alias).
float fieldZP(float z) { float a = 0.0402 * z; return a / (1.0 + a / 30.0); }
float2 fieldPseudo(float2 g) { float zp = fieldZP(g.y); return float2(g.x * zp / (0.1608 * max(g.y, 1.0)), zp); }
float fieldV(float z) { return saturate(1.0 - 26.2 / max(z, 1.0)); }        // 0 near .. 1 far
float fieldHazeAt(float z) { return (1.0 - exp(-fieldZP(z) * 0.035)) * 0.55 + 0.20 * smoothstep(0.90, 1.0, fieldV(z)); }

// ---------------------------------------------------------------------------
// Railway yard: the track, buffer stops, utility poles and wires, the sheds,
// the barn on the rise and the footbridge station
//
// Everything here is modelled in metres and seen through the same long-lens
// camera as the sky: the eye is EYE_M above the field, looking along +z (x right,
// y up). A field point at distance z lies EYE_M / (z SKY_TAN) below the horizon -
// the same perspective the grass rows follow - so the buildings, poles and track
// sit in the meadow at consistent scale. The structures are signed distance
// fields, ray-marched, lit by the sun (soft shadows, also cast onto the field),
// the blue sky and the meadow's bounce, through a soft painted ramp; boards,
// corrugations, rust, windows and stains are procedural.
// ---------------------------------------------------------------------------

static const float EYE_M = 4.0;           // eye above the field (a slight rise)
static const float GAUGE_HALF = 0.7175;   // 1435 mm standard gauge

float3 sunWorld() { return normalize(float3(0.74, 0.46, 0.48)); }   // the clouds' sun, z forward

float3 viewRay(float2 p, float aspect)
{
    return normalize(float3((p.x - aspect * 0.5) * SKY_TAN, (p.y - HORIZON) * SKY_TAN, 1.0));
}

float2 projectWorld(float3 w, float aspect)
{
    float k = 1.0 / (max(w.z, 0.1) * SKY_TAN);
    return float2(aspect * 0.5 + w.x * k, HORIZON + (w.y - EYE_M) * k);
}

// Where pixel p's view ray meets the field: (x, height, z) in metres; z < 0 for sky.
float3 fieldHit(float2 p, float aspect)
{
    float3 ro = float3(0.0, EYE_M, 0.0);
    float3 rd = viewRay(p, aspect);
    if (rd.y > 0.012) return float3(0.0, 0.0, -1.0);
    float t = 2.0;
    float tPrev = t;
    for (int i = 0; i < 220; i++)
    {
        float3 q = ro + rd * t;
        float d = q.y - terrainH(q.xz);
        if (d < 0.0)
        {
            float a = tPrev;
            float b = t;
            for (int k = 0; k < 8; k++)
            {
                float m = 0.5 * (a + b);
                float3 qm = ro + rd * m;
                if (qm.y - terrainH(qm.xz) < 0.0) b = m; else a = m;
            }
            float3 hp = ro + rd * b;
            return float3(hp.x, terrainH(hp.xz), hp.z);
        }
        if (t > 6000.0) break;
        tPrev = t;
        t += max(0.008 * t, 0.7 * d / (max(-rd.y, 0.0) + 0.06));
    }
    return float3(0.0, 0.0, -1.0);
}

// --- Track --------------------------------------------------------------------

// Centre lines, laid out as a railway is: straight runs joined by circular
// curves (100 m radius on the main line, 70-80 m on the spurs), sampled every
// 3 m. The main line comes down past the barn and swings right along the
// station platform; two spurs leave it tangentially at turnouts and curve
// gently toward the camera to end at buffer stops. (Generated: straight runs
// filleted with arcs.)
static const int TRACK_N = 65;
static const int TRACK_MAIN0 = 0; static const int TRACK_MAIN1 = 41;
static const int TRACK_A0 = 42; static const int TRACK_A1 = 50;
static const int TRACK_B0 = 51; static const int TRACK_B1 = 64;
static const float2 TRACK[65] = {
    float2(-100.00, 345.00), float2(-54.70, 228.93), float2(-53.30, 225.49), float2(-51.77, 222.11),
    float2(-50.14, 218.77), float2(-48.39, 215.50), float2(-27.65, 178.17), float2(-26.09, 175.46),
    float2(-24.45, 172.81), float2(-22.73, 170.22), float2(-20.93, 167.67), float2(-19.05, 165.19),
    float2(-17.09, 162.76), float2(-15.06, 160.39), float2(-12.96, 158.09), float2(-10.78, 155.86),
    float2(-8.54, 153.70), float2(-6.23, 151.60), float2(-3.86, 149.58), float2(-1.42, 147.64),
    float2(1.07, 145.77), float2(3.62, 143.98), float2(6.23, 142.27), float2(8.89, 140.64),
    float2(11.59, 139.10), float2(14.35, 137.64), float2(17.15, 136.27), float2(21.78, 134.08),
    float2(24.56, 132.83), float2(27.38, 131.67), float2(30.24, 130.61), float2(33.13, 129.65),
    float2(36.05, 128.78), float2(39.00, 128.02), float2(41.98, 127.35), float2(44.97, 126.79),
    float2(47.98, 126.32), float2(51.01, 125.96), float2(54.05, 125.71), float2(57.09, 125.55),
    float2(60.14, 125.50), float2(200.00, 125.50), float2(-74.55, 279.79), float2(-66.63, 259.48),
    float2(-65.86, 257.42), float2(-65.14, 255.34), float2(-25.78, 135.41), float2(-24.68, 131.78),
    float2(-23.76, 128.11), float2(-23.01, 124.39), float2(-11.00, 56.50), float2(-43.26, 206.27),
    float2(-34.03, 189.66), float2(-33.56, 188.79), float2(-33.09, 187.91), float2(-8.03, 139.61),
    float2(-6.60, 136.71), float2(-5.32, 133.74), float2(-4.17, 130.72), float2(-3.16, 127.65),
    float2(-2.30, 124.53), float2(-1.57, 121.38), float2(-1.00, 118.20), float2(-0.57, 114.99),
    float2(2.00, 91.50)
};

// Nearest point on the polyline TRACK[i0..i1]: x = signed offset across (m),
// y = distance along (m), z = how far past either end (m); dir = its direction.
float3 trackLocal(float2 g, int i0, int i1, out float2 dir)
{
    float best = 1e9;
    float3 r = float3(1e3, 0.0, 1e3);
    dir = float2(0.0, 1.0);
    float acc = 0.0;
    for (int i = i0; i < i1; i++)
    {
        float2 a = TRACK[i];
        float2 ba = TRACK[i + 1] - a;
        float len = length(ba);
        float2 td = ba / len;
        float u = dot(g - a, td);
        float h = clamp(u, 0.0, len);
        float2 q = g - a - td * h;
        float d2 = dot(q, q);
        if (d2 < best)
        {
            best = d2;
            float over = (i == i0 ? max(-u, 0.0) : 0.0) + (i == i1 - 1 ? max(u - len, 0.0) : 0.0);
            r = float3(dot(g - a, float2(td.y, -td.x)), acc + h, over);
            dir = td;
        }
        acc += len;
    }
    return r;
}

float3 trackNearest(float2 g, out float2 dir)
{
    float2 d1;
    float2 d2;
    float3 a = trackLocal(g, TRACK_MAIN0, TRACK_MAIN1, dir);
    float3 b = trackLocal(g, TRACK_A0, TRACK_A1, d1);
    float3 c = trackLocal(g, TRACK_B0, TRACK_B1, d2);
    // A spur's first metres overlap the main line at its turnout: there the
    // main line wins, so the two run into each other smoothly.
    if (abs(b.x) + b.z < abs(a.x) + a.z) { a = b; dir = d1; }
    if (abs(c.x) + c.z < abs(a.x) + a.z) { a = c; dir = d2; }
    return a;
}

// How much track bed (ballast) covers field point g, 0..1, with a ragged edge.
float trackBed(float2 g)
{
    if (g.y < 40.0 || g.x < -110.0) return 0.0;
    float2 dir;
    float3 tr = trackNearest(g, dir);
    float e = abs(tr.x) + tr.z * 1.5;
    float edge = 2.35 + (vnoise(g * 0.9) - 0.5) * 0.5;
    return 1.0 - smoothstep(edge - 0.3, edge + 0.15, e);
}

// Ballast spilled around the track bed, laid on the field: albedo (rgb) and
// coverage (a); fp is the pixel's footprint on the ground, for filtering.
float4 trackDecal(float2 g, float2 fp)
{
    if (g.y < 40.0 || g.x < -110.0) return float4(0, 0, 0, 0);
    float2 dir;
    float3 tr = trackNearest(g, dir);
    float e = abs(tr.x) + tr.z * 1.5;
    if (e > 2.8) return float4(0, 0, 0, 0);
    float fn = max(length(float2(dir.y * fp.x, dir.x * fp.y)), 1e-4);
    float edge = 2.20 + (vnoise(g * 0.9) - 0.5) * 0.4;
    float bed = 1.0 - smoothstep(edge - 0.20 - fn, edge + 0.05 + fn, e);
    float stones = vnoise(g * 9.0) * 0.6 + vnoise(g * 23.0) * 0.4;
    float3 alb = float3(0.20, 0.17, 0.12) * lerp(0.62, 1.15, lerp(stones, 0.5, saturate(fn * 3.0)));
    float weeds = smoothstep(0.50, 0.75, fbm(g * float2(0.5, 0.8) + 7.0, 3)) * smoothstep(0.4, 1.4, abs(tr.x));
    alb = lerp(alb, float3(0.10, 0.19, 0.05), weeds * 0.7);
    return float4(alb, bed * (1.0 - weeds * 0.4));
}

// --- Structures ---------------------------------------------------------------

static const int M_PLANK  = 1;   // weathered board walls (silvered, lilac grey)
static const int M_DOOR   = 2;   // barn door boards
static const int M_WOOD   = 3;   // dark timber: braces, trestles, posts
static const int M_RUST   = 4;   // rusty corrugated roofing
static const int M_TIN    = 5;   // blue-grey corrugated roofing
static const int M_CONC   = 6;   // concrete: poles, platform
static const int M_STEEL  = 7;   // painted steel frame
static const int M_PANEL  = 8;   // footbridge walls, window band
static const int M_STAIR  = 9;   // stairway walls (stair coordinates)
static const int M_HOUSE  = 10;  // plastered house walls, windows
static const int M_SIGN   = 11;  // buffer-stop board
static const int M_PORC   = 12;  // insulators, plates
static const int M_METAL  = 13;  // galvanised fittings, transformer, lamp
static const int M_DARK   = 14;  // tarred boards of the small hut
static const int M_BALLAST = 15; // track bed stones
static const int M_RAIL   = 16;  // rails: rusty web, worn head
static const int M_SLEEPER = 17; // weathered sleepers

struct SHit
{
    float  d;
    int    mat;
    float3 lp;    // texture coordinates (object or part frame, metres)
    float  ag;    // height above the object's own ground
};

void addHit(inout SHit h, float d, int mat, float3 lp, float ag)
{
    if (d < h.d) { h.d = d; h.mat = mat; h.lp = lp; h.ag = ag; }
}

float sdBox(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdSegment(float3 p, float3 a, float3 b, float r)
{
    float3 pa = p - a;
    float3 ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - r;
}

// World to object frame: translate, then turn by yaw about y.
float3 toLocal(float3 w, float3 pos, float yaw)
{
    float3 p = w - pos;
    float c = cos(yaw);
    float s = sin(yaw);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

// Solid gable: ridge along z at height h above y = 0, eaves at x = +-w, length +-l.
float sdGable(float3 p, float w, float h, float l)
{
    float k = h / w;
    float pl = (p.y + k * abs(p.x) - h) / sqrt(1.0 + k * k);
    return max(max(pl, -p.y), abs(p.z) - l);
}

// Roof sheet lying on such a gable: thickness 2 th, overhang o.
float sdGableRoof(float3 p, float w, float h, float l, float th, float o)
{
    float k = h / w;
    float pl = (p.y + k * abs(p.x) - h) / sqrt(1.0 + k * k);
    return max(max(abs(pl - th) - th, abs(p.x) - (w + o)), abs(p.z) - (l + o));
}

// Positions on the field (y is added to the terrain height there).
static const float3 BARN_POS   = float3(-22.0, 0.0, 200.0);
static const float  BARN_YAW   = 0.45;
static const float3 HOUSE_POS  = float3(-35.0, 0.0, 206.0);
static const float  HOUSE_YAW  = 0.30;
static const float3 SHED_POS   = float3(-4.0, 0.0, 180.0);
static const float  SHED_YAW   = 0.12;
static const float3 HUT_POS    = float3(6.0, 0.0, 215.0);
static const float  HUT_YAW    = -0.25;
static const float3 BRIDGE_POS = float3(22.0, 0.0, 134.5);   // platform edge clear of the ballast
static const float3 POLE_POS[4] = { float3(-19.5, 0.0, 62.0), float3(-34.5, 0.0, 140.0), float3(-22.5, 0.0, 185.0), float3(9.0, 0.0, 205.0) };
static const float  POLE_H[4]   = { 15.0, 11.0, 10.0, 9.0 };
static const float3 TREE_POS   = float3(22.0, 0.0, 148.0);   // the lone tree
static const float  TREE_M     = 11.0;                        // its height
static const float3 STOP_POS[2] = { float3(-11.0, 0.0, 55.5), float3(2.0, 0.0, 90.5) };
static const float  STOP_YAW[2] = { 0.1751, 0.1092 };

float3 onGround(float3 pos) { return float3(pos.x, pos.y + terrainH(pos.xz), pos.z); }

// The barn: tall board walls, a gable roof of rusty corrugated iron, and big
// double doors with X braces in the gable end.
void barnSDF(inout SHit h, float3 wp)
{
    float3 lp = toLocal(wp, onGround(BARN_POS), BARN_YAW);
    float body = min(sdBox(lp - float3(0.0, 3.0, 0.0), float3(5.5, 3.0, 7.0)), sdGable(lp - float3(0.0, 6.0, 0.0), 5.5, 3.4, 7.0));
    body = max(body, -sdBox(lp - float3(0.0, 2.5, -7.0), float3(3.3, 2.5, 0.12)));   // door opening
    addHit(h, body, M_PLANK, lp, lp.y);
    addHit(h, sdBox(lp - float3(0.0, 2.45, -6.90), float3(3.25, 2.45, 0.04)), M_DOOR, lp, lp.y);
    float fr = 1e3;
    for (int k = 0; k < 2; k++)
    {
        float x0 = k == 0 ? -3.05 : 0.20;
        float x1 = x0 + 2.85;
        fr = min(fr, sdSegment(lp, float3(x0, 0.45, -6.93), float3(x1, 4.45, -6.93), 0.10));
        fr = min(fr, sdSegment(lp, float3(x1, 0.45, -6.93), float3(x0, 4.45, -6.93), 0.10));
    }
    fr = min(fr, sdBox(lp - float3(0.0, 4.72, -6.95), float3(3.30, 0.14, 0.07)));
    fr = min(fr, sdBox(lp - float3(0.0, 0.18, -6.95), float3(3.30, 0.14, 0.07)));
    fr = min(fr, sdBox(lp - float3(0.0, 2.45, -6.95), float3(0.10, 2.45, 0.07)));
    fr = min(fr, sdBox(lp - float3(-3.36, 2.55, -7.02), float3(0.12, 2.55, 0.08)));
    fr = min(fr, sdBox(lp - float3(3.36, 2.55, -7.02), float3(0.12, 2.55, 0.08)));
    fr = min(fr, sdBox(lp - float3(0.0, 5.18, -7.02), float3(3.5, 0.12, 0.08)));     // lintel
    fr = min(fr, sdBox(lp - float3(0.0, 7.2, -7.02), float3(0.55, 0.45, 0.06)));     // gable vent frame
    addHit(h, fr, M_WOOD, lp, lp.y);
    addHit(h, sdGableRoof(lp - float3(0.0, 6.0, 0.0), 5.5, 3.4, 7.0, 0.09, 0.45), M_RUST, lp, lp.y);
}

// The low house beside it: plastered walls with windows, a shallow tin roof.
void houseSDF(inout SHit h, float3 wp)
{
    float3 lp = toLocal(wp, onGround(HOUSE_POS), HOUSE_YAW);
    addHit(h, sdBox(lp - float3(0.0, 1.6, 0.0), float3(3.0, 1.6, 2.4)), M_HOUSE, lp, lp.y);
    float3 rp = float3(lp.z, lp.y - 3.2, lp.x);
    addHit(h, sdGable(rp, 2.4, 1.1, 3.0), M_HOUSE, lp, lp.y);
    addHit(h, sdGableRoof(rp, 2.4, 1.1, 3.0, 0.07, 0.35), M_TIN, lp, lp.y);
    addHit(h, sdBox(lp - float3(1.9, 4.0, 0.6), float3(0.2, 0.6, 0.2)), M_CONC, lp, lp.y);   // chimney
}

// An open shed: posts, a board back wall, a lean-to roof of rusty iron.
void shedSDF(inout SHit h, float3 wp)
{
    float3 lp = toLocal(wp, onGround(SHED_POS), SHED_YAW);
    float posts = 1e3;
    for (int i = 0; i < 4; i++)
    {
        float x = -6.0 + 4.0 * float(i);
        posts = min(posts, sdBox(lp - float3(x, 1.6, -2.4), float3(0.1, 1.6, 0.1)));
        posts = min(posts, sdBox(lp - float3(x, 1.5, 2.4), float3(0.1, 1.5, 0.1)));
    }
    posts = min(posts, sdBox(lp - float3(0.0, 3.1, -2.4), float3(6.1, 0.1, 0.1)));
    addHit(h, posts, M_WOOD, lp, lp.y);
    float walls = sdBox(lp - float3(0.0, 1.5, 2.4), float3(6.0, 1.5, 0.06));
    walls = min(walls, sdBox(lp - float3(-6.0, 1.5, 0.0), float3(0.06, 1.5, 2.4)));
    walls = min(walls, sdBox(lp - float3(-3.6, 0.55, -2.4), float3(2.4, 0.55, 0.05)));
    addHit(h, walls, M_PLANK, lp, lp.y);
    float roof = sdBox(float3(lp.x, lp.y - (3.25 - 0.07 * lp.z), lp.z), float3(6.5, 0.06, 3.0));
    addHit(h, roof, M_RUST, lp, lp.y);
}

// A small tarred hut.
void hutSDF(inout SHit h, float3 wp)
{
    float3 lp = toLocal(wp, onGround(HUT_POS), HUT_YAW);
    addHit(h, sdBox(lp - float3(0.0, 1.3, 0.0), float3(2.4, 1.3, 1.8)), M_DARK, lp, lp.y);
    float3 rp = float3(lp.z, lp.y - 2.6, lp.x);
    addHit(h, sdGable(rp, 1.8, 1.2, 2.4), M_DARK, lp, lp.y);
    addHit(h, sdGableRoof(rp, 1.8, 1.2, 2.4, 0.06, 0.3), M_RUST, lp, lp.y);
}

// The station platform: a concrete platform along the main line with a long
// canopy of rusty iron on steel posts and a board fence along its back.
void bridgeSDF(inout SHit h, float3 wp)
{
    float3 lp = wp - onGround(BRIDGE_POS);
    // Canopy: posts every 6 m along a beam.
    float px6 = clamp(round((lp.x - 20.0) / 6.0), 0.0, 9.0) * 6.0 + 20.0;
    float fr = sdBox(lp - float3(px6, 1.75, -2.0), float3(0.10, 1.75, 0.10));
    fr = min(fr, sdBox(lp - float3(48.0, 3.33, -2.0), float3(30.0, 0.10, 0.10)));
    addHit(h, fr, M_STEEL, lp, lp.y);
    float cz = lp.z + 2.0;
    addHit(h, sdBox(float3(lp.x - 48.0, lp.y - (3.55 + 0.16 * cz), cz), float3(30.0, 0.07, 3.2)), M_RUST, lp, lp.y);
    addHit(h, sdBox(lp - float3(48.0, 3.10, -5.2), float3(30.0, 0.28, 0.05)), M_STEEL, lp, lp.y);
    addHit(h, sdBox(lp - float3(48.0, 1.55, 0.9), float3(30.0, 0.65, 0.06)), M_PLANK, lp, lp.y);
    addHit(h, sdBox(lp - float3(48.0, 0.45, -2.0), float3(32.0, 0.45, 3.0)), M_CONC, lp, lp.y);
}

// The track, modelled: a raised ballast bed (flat top 3 m wide, 25 cm high,
// sloping shoulders), sleepers bedded in it, steel tie plates under the rails,
// and flat-bottomed rails (head, web, foot) with fishplated joints every 25 m;
// it all follows the lie of the land, and the spurs end at their buffer stops.
void trackSDF(inout SHit h, float3 wp)
{
    float2 dir;
    float3 tr = trackNearest(wp.xz, dir);
    float off = tr.x;
    float y = wp.y - terrainH(wp.xz);
    float past = tr.z;
    float3 tp = float3(off, y, tr.y);
    float bed = max(max(y - 0.25, (abs(off) - 2.05 + 1.8 * y) / 2.06), max(-y - 0.4, past - 1.6));
    addHit(h, bed, M_BALLAST, tp, y);
    // Sleepers: 2.6 m long, 26 cm wide, every 1.4 m, their tops just proud of the stones.
    float sc = (frac(tr.y / 1.4) - 0.5) * 1.4;
    float sl = max(sdBox(float3(sc, y - 0.27, off), float3(0.13, 0.08, 1.30)), past - 0.25);
    addHit(h, sl, M_SLEEPER, tp, y);
    float ro = abs(abs(off) - GAUGE_HALF);
    float plate = max(sdBox(float3(sc, y - 0.36, ro), float3(0.10, 0.012, 0.11)), past - 0.25);
    addHit(h, plate, M_METAL, tp, y);
    // Rail: head 7 cm wide, web, 13 cm foot; 16 cm tall.
    float rail = min(sdBox(float3(ro, y - 0.495, 0.0), float3(0.036, 0.022, 1e3)),
                     min(sdBox(float3(ro, y - 0.43, 0.0), float3(0.010, 0.050, 1e3)),
                         sdBox(float3(ro, y - 0.383, 0.0), float3(0.065, 0.011, 1e3))));
    addHit(h, max(rail, past), M_RAIL, tp, y);
    // Fishplates at the rail joints.
    float jz = (frac(tr.y / 25.0) - 0.5) * 25.0;
    float fish = max(sdBox(float3(ro, y - 0.44, jz), float3(0.028, 0.035, 0.30)), past);
    addHit(h, fish, M_RAIL, tp, y);
}

// A concrete utility pole with crossarms and insulators; the near one also
// carries a transformer, a street lamp, step bolts, a plate and an aerial.
void poleSDF(inout SHit h, float3 wp, int i)
{
    float3 lp = wp - onGround(POLE_POS[i]);
    float H = POLE_H[i];
    float r = lerp(0.19, 0.12, saturate(lp.y / H)) * (i == 0 ? 1.0 : 0.9);
    addHit(h, max(length(lp.xz) - r, max(-lp.y, lp.y - H)), M_CONC, lp, lp.y);
    float arms = sdBox(lp - float3(0.0, H - 0.45, 0.0), float3(1.05, 0.05, 0.05));
    arms = min(arms, sdBox(lp - float3(0.0, H - 1.25, 0.0), float3(0.85, 0.05, 0.05)));
    arms = min(arms, sdSegment(lp, float3(-0.65, H - 0.45, 0.0), float3(0.0, H - 1.0, 0.0), 0.025));
    arms = min(arms, sdSegment(lp, float3(0.65, H - 0.45, 0.0), float3(0.0, H - 1.0, 0.0), 0.025));
    addHit(h, arms, M_METAL, lp, lp.y);
    float ins = 1e3;
    for (int k = 0; k < 5; k++)
    {
        float x = k == 0 ? -0.9 : (k == 1 ? -0.35 : (k == 2 ? 0.9 : (k == 3 ? -0.7 : 0.7)));
        float y = k < 3 ? H - 0.40 : H - 1.20;
        ins = min(ins, sdSegment(lp, float3(x, y, 0.0), float3(x, y + 0.16, 0.0), 0.055));
    }
    addHit(h, ins, M_PORC, lp, lp.y);
    if (i == 0)
    {
        float tr = max(length(lp.xz - float2(0.50, 0.0)) - 0.30, abs(lp.y - (H - 4.2)) - 0.55);
        tr = min(tr, sdBox(lp - float3(0.25, H - 4.2, 0.0), float3(0.12, 0.35, 0.05)));
        tr = min(tr, sdSegment(lp, float3(0.0, H - 7.0, 0.0), float3(-1.2, H - 6.6, 0.0), 0.04));
        tr = min(tr, sdSegment(lp, float3(-1.2, H - 6.6, 0.0), float3(-1.45, H - 6.75, 0.0), 0.03));
        tr = min(tr, sdBox(lp - float3(-1.55, H - 6.82, 0.0), float3(0.28, 0.06, 0.13)));
        float cy = floor(lp.y / 0.45);
        float yb = clamp(cy * 0.45 + 0.225, 2.2, H - 2.0);
        float side = fmod(cy, 2.0) < 0.5 ? 1.0 : -1.0;
        tr = min(tr, sdSegment(lp, float3(0.0, yb, 0.0), float3(side * 0.32, yb, -0.04), 0.022));
        tr = min(tr, sdSegment(lp, float3(0.0, H, 0.0), float3(0.0, H + 1.2, 0.0), 0.03));
        tr = min(tr, sdSegment(lp, float3(-0.35, H + 1.0, 0.0), float3(0.35, H + 1.0, 0.0), 0.02));
        addHit(h, tr, M_METAL, lp, lp.y);
        addHit(h, sdBox(lp - float3(0.0, 2.6, -0.17), float3(0.12, 0.30, 0.02)), M_PORC, lp, lp.y);
    }
}

// A wooden buffer stop: two posts, raking struts behind, a stop beam, cross
// bracing, and the board on top. Local -z faces the camera, the track runs off +z.
void stopSDF(inout SHit h, float3 wp, int i)
{
    float3 lp = toLocal(wp, onGround(STOP_POS[i]), STOP_YAW[i]);
    // Two A-frames across the track, legs splayed outside the rails, tied by a
    // ridge beam, a cross bar and diagonal braces; the stop beam faces the track.
    float w = 1e3;
    for (int k = 0; k < 2; k++)
    {
        float z = k == 0 ? -0.55 : 0.55;
        w = min(w, sdSegment(lp, float3(-0.22, 2.0, z), float3(-1.15, 0.0, z), 0.08));
        w = min(w, sdSegment(lp, float3(0.22, 2.0, z), float3(1.15, 0.0, z), 0.08));
        w = min(w, sdBox(lp - float3(0.0, 0.85, z), float3(0.82, 0.07, 0.06)));
    }
    w = min(w, sdBox(lp - float3(0.0, 2.02, 0.0), float3(0.30, 0.09, 0.75)));
    w = min(w, sdSegment(lp, float3(-0.7, 0.9, -0.55), float3(-0.35, 1.8, 0.55), 0.04));
    w = min(w, sdSegment(lp, float3(0.7, 0.9, -0.55), float3(0.35, 1.8, 0.55), 0.04));
    w = min(w, sdBox(lp - float3(0.0, 0.70, 0.72), float3(1.05, 0.13, 0.10)));
    w = min(w, sdBox(lp - float3(0.0, 2.30, 0.0), float3(0.05, 0.25, 0.05)));
    addHit(h, w, M_WOOD, lp, lp.y);
    float3 sp = lp - float3(0.0, 2.75, 0.0);
    addHit(h, sdBox(sp, float3(0.38, 0.38, 0.03)), M_SIGN, sp, lp.y);
}

// Bounding boxes (world centre, half size) for culling: barn, house, shed, hut,
// footbridge, poles 1-4, buffer stops 1-2; bit i of a mask enables object i.
static const int YARD_N = 15;
static const int YARD_ALL = 0x7EFF;   // all but the unused fourth pole
static const float3 YARD_C[15] = {
    float3(-22.0, 5.0, 200.0), float3(-35.0, 2.4, 206.0), float3(-4.0, 2.0, 180.0), float3(6.0, 1.9, 215.0),
    float3(70.0, 2.4, 132.1), float3(-19.5, 8.1, 62.0), float3(-34.5, 6.2, 140.0), float3(-22.5, 5.7, 185.0),
    float3(9.0, 5.2, 205.0), float3(-11.0, 1.6, 55.5), float3(2.0, 1.6, 90.5),
    float3(-63.8, 3.5, 261.6), float3(86.2, 0.5, 151.8), float3(-42.8, 3.5, 168.1), float3(-20.6, 2.5, 148.9)
};
static const float3 YARD_H[15] = {
    float3(9.5, 5.6, 9.5), float3(4.5, 2.7, 4.5), float3(7.2, 2.3, 4.0), float3(3.5, 2.4, 3.5),
    float3(33.0, 2.6, 4.6), float3(1.9, 8.4, 1.0), float3(1.3, 6.4, 0.6), float3(1.3, 5.9, 0.6),
    float3(1.3, 5.4, 0.6), float3(1.5, 1.9, 1.4), float3(1.5, 1.9, 1.4),
    float3(39.2, 6.0, 86.4), float3(116.8, 2.5, 29.3), float3(34.8, 6.0, 114.6), float3(25.6, 5.0, 60.4)
};

SHit yardSDF(float3 wp, int mask)
{
    SHit h;
    h.d = 1e4;
    h.mat = 0;
    h.lp = float3(0.0, 0.0, 0.0);
    h.ag = 0.0;
    if ((mask & 1) != 0) barnSDF(h, wp);
    if ((mask & 2) != 0) houseSDF(h, wp);
    if ((mask & 4) != 0) shedSDF(h, wp);
    if ((mask & 8) != 0) hutSDF(h, wp);
    if ((mask & 16) != 0) bridgeSDF(h, wp);
    for (int i = 0; i < 3; i++)                          // the fourth pole is unused
        if ((mask & (32 << i)) != 0) poleSDF(h, wp, i);
    for (int i = 0; i < 2; i++)
        if ((mask & (512 << i)) != 0) stopSDF(h, wp, i);
    if ((mask & 0x7800) != 0) trackSDF(h, wp);
    return h;
}

// Objects whose boxes the ray crosses within (0, tFar), and the span they cover.
int yardCull(float3 ro, float3 rd, float tFar, int allow, out float2 span)
{
    int mask = 0;
    span = float2(1e9, -1e9);
    float3 inv = 1.0 / (rd + float3(1e-7, 1e-7, 1e-7));
    for (int i = 0; i < YARD_N; i++)
    {
        if ((allow & (1 << i)) == 0) continue;
        float3 c = YARD_C[i];
        if (i < 11) c.y += terrainH(c.xz);
        float3 t0 = (c - YARD_H[i] - ro) * inv;
        float3 t1 = (c + YARD_H[i] - ro) * inv;
        float3 tn = min(t0, t1);
        float3 tf = max(t0, t1);
        float a = max(max(tn.x, tn.y), tn.z);
        float b = min(min(tf.x, tf.y), tf.z);
        if (a <= b && b > 0.0 && a < tFar)
        {
            mask |= 1 << i;
            span = float2(min(span.x, max(a, 0.0)), max(span.y, min(b, tFar)));
        }
    }
    return mask;
}

// Soft sun shadow from the structures (1 = lit).
float yardShadow(float3 ro, int allow)
{
    float3 L = sunWorld();
    float2 span;
    int mask = yardCull(ro, L, 120.0, allow, span);
    if (mask == 0) return 1.0;
    float res = 1.0;
    float t = max(span.x, 0.04);
    for (int i = 0; i < 64 && t < span.y; i++)
    {
        float d = yardSDF(ro + L * t, mask).d;
        res = min(res, 12.0 * d / t);
        if (res < 0.02) return 0.0;
        t += clamp(d, 0.03, 1.5);
    }
    return saturate(res);
}

// Shadow the structures cast onto field point w.
float yardGroundShadow(float3 w)
{
    if (w.z <= 0.0) return 1.0;
    return yardShadow(w + float3(0.0, 0.08, 0.0), YARD_ALL);
}

float3 yardNormal(float3 p, int mask, float e)
{
    const float2 k = float2(1.0, -1.0);
    return normalize(k.xyy * yardSDF(p + k.xyy * e, mask).d + k.yyx * yardSDF(p + k.yyx * e, mask).d
                   + k.yxy * yardSDF(p + k.yxy * e, mask).d + k.xxx * yardSDF(p + k.xxx * e, mask).d);
}

// --- Global illumination --------------------------------------------------------
//
// The structures are lit by one-bounce path tracing: cosine-weighted rays from
// each shaded point are traced against the structures' distance fields, the
// field's heightfield and the sky dome. A ray that meets the sunlit meadow
// brings back its warm green bounce, one that meets a wall brings that wall's
// light, one that escapes brings the sky's (deep blue overhead, pale at the
// horizon, brighter toward the sun). Glass, steel and the worn rail heads
// trace a mirror ray the same way. The field in turn traces a few rays to see
// how much sky the structures hide from it.

static const int   GI_RAYS  = 8;
static const float GI_RANGE = 40.0;    // metres a bounce ray is followed

// Radiance of the clear sky dome in world direction d (y up, z forward).
float3 skyDome(float3 d)
{
    float e = d.y;
    float3 c = lerp(float3(0.62, 0.76, 0.90), float3(0.14, 0.30, 0.66), smoothstep(0.0, 0.30, e));
    c = lerp(c, float3(0.040, 0.110, 0.320), smoothstep(0.30, 0.95, e));
    c += float3(0.50, 0.48, 0.40) * pow(saturate(dot(d, sunWorld())), 12.0);       // aureole
    c = lerp(c, float3(0.95, 0.98, 1.00), 0.30 * exp(-max(e, 0.0) * 14.0));        // the cumulus band
    // Below the skyline: the far meadow.
    return lerp(c, float3(0.40, 0.44, 0.16), smoothstep(0.0, -0.04, e));
}

// Cosine-weighted direction about n: sample k of n, stratified in radius and
// spread by the golden angle, the whole set turned by a per-pixel `rot`.
float3 cosineDir(float3 n, int k, int count, float rot, float jit)
{
    float3 ta = normalize(abs(n.y) < 0.9 ? cross(n, float3(0.0, 1.0, 0.0)) : cross(n, float3(1.0, 0.0, 0.0)));
    float3 tb = cross(n, ta);
    float u = (float(k) + jit) / float(count);
    float r = sqrt(u);
    float phi = float(k) * 2.39996 + rot;
    return normalize(ta * (r * cos(phi)) + tb * (r * sin(phi)) + n * sqrt(max(1.0 - u, 0.0)));
}

// Where a ray from ro meets the field within tMax metres, or -1.
float traceField(float3 ro, float3 rd, float tMax)
{
    if (rd.y > 0.03) return -1.0;
    float t = 0.02;
    float tPrev = t;
    for (int i = 0; i < 24 && t < tMax; i++)
    {
        float3 q = ro + rd * t;
        float d = q.y - terrainH(q.xz);
        if (d < 0.0)
        {
            float a = tPrev;
            float b = t;
            for (int k = 0; k < 4; k++)
            {
                float m = 0.5 * (a + b);
                float3 qm = ro + rd * m;
                if (qm.y - terrainH(qm.xz) < 0.0) b = m; else a = m;
            }
            return b;
        }
        tPrev = t;
        t += max(0.6 * d / (max(-rd.y, 0.0) + 0.04), 0.05);
    }
    return -1.0;
}

// First structure a ray from ro meets within tMax (distance, or -1), and its mask.
float traceYard(float3 ro, float3 rd, float tMax, int allow, int steps, out int mask)
{
    float2 span;
    mask = yardCull(ro, rd, tMax, allow, span);
    if (mask == 0) return -1.0;
    float t = max(span.x, 0.02);
    for (int i = 0; i < steps && t < span.y; i++)
    {
        float d = yardSDF(ro + rd * t, mask).d;
        if (d < 0.004 + 0.002 * t) return t;
        t += d;
    }
    return -1.0;
}

// Soft sun shadow from the structures on a cheap budget (for bounce points).
float yardShadowFast(float3 ro)
{
    float3 L = sunWorld();
    float2 span;
    int mask = yardCull(ro, L, 60.0, YARD_ALL, span);
    if (mask == 0) return 1.0;
    float res = 1.0;
    float t = max(span.x, 0.05);
    for (int i = 0; i < 20 && t < span.y; i++)
    {
        float d = yardSDF(ro + L * t, mask).d;
        res = min(res, 8.0 * d / t);
        if (res < 0.02) return 0.0;
        t += clamp(d, 0.08, 3.0);
    }
    return saturate(res);
}

// Radiance arriving at ro from direction rd: the lit field, a lit structure or the sky.
float3 traceRadiance(float3 ro, float3 rd, float t)
{
    int mask;
    float ty = traceYard(ro, rd, GI_RANGE, YARD_ALL, 40, mask);
    float tf = traceField(ro, rd, ty > 0.0 ? ty : GI_RANGE);
    float3 L = sunWorld();
    if (tf > 0.0)
    {
        float3 g = ro + rd * tf;
        float vis = cloudShadowW(g.xz, t) * yardShadowFast(g + float3(0.0, 0.08, 0.0));
        float ndl = 0.56 * saturate(dot(terrainNormal(g.xz), L)) / L.y;
        float4 td = trackDecal(g.xz, float2(0.05, 0.05));
        float3 alb = lerp(meadowAlbedo(g.xz), td.rgb, td.a);
        return alb * (SUN * ndl * vis + SKY_AMB * 0.42);
    }
    if (ty > 0.0)
    {
        float3 q = ro + rd * ty;
        SHit h = yardSDF(q, mask);
        float3 n = yardNormal(q, mask, 0.01);
        float gl;
        float3 alb = yardAlbedo(h.mat, h.lp, n, h.ag, 0.08, gl);
        float sun = saturate(dot(n, L)) * cloudShadowW(q.xz - L.xz / L.y * h.ag, t);
        return alb * (SUN * 0.95 * sun * 0.8 + skyDome(normalize(n + float3(0.0, 0.6, 0.0))) * 0.55);
    }
    return skyDome(rd);
}

// Light gathered at a structure's surface point P (normal n) from the scene
// around it: under cosine sampling a matte surface reflects albedo times the
// mean radiance of the rays.
float3 yardIrradiance(float3 P, float3 n, float rot, float jit, float t)
{
    float3 sum = float3(0.0, 0.0, 0.0);
    for (int k = 0; k < GI_RAYS; k++)
        sum += traceRadiance(P, cosineDir(n, k, GI_RAYS, rot, jit), t);
    return sum / float(GI_RAYS);
}

// How much of the sky a field point sees past the structures (1 = all of it),
// and the light the walls in the way send back instead (`bounce`).
float fieldSkyVis(float3 w, float rot, float jit, float t, out float3 bounce)
{
    bounce = float3(0.0, 0.0, 0.0);
    // Only points near a building or pole are worth tracing.
    bool near = false;
    for (int i = 0; i < 11; i++)
    {
        float2 dd = abs(w.xz - YARD_C[i].xz) - YARD_H[i].xz;
        if (max(dd.x, dd.y) < 2.5 * YARD_H[i].y + 2.0) near = true;
    }
    if (!near) return 1.0;
    float3 L = sunWorld();
    float3 ro = w + float3(0.0, 0.10, 0.0);
    float vis = 0.0;
    const int N = 4;
    for (int k = 0; k < N; k++)
    {
        float3 d = cosineDir(float3(0.0, 1.0, 0.0), k, N, rot, jit);
        int mask;
        float ty = traceYard(ro, d, 30.0, 0x6FF, 28, mask);
        if (ty < 0.0) { vis += 1.0; continue; }
        float3 q = ro + d * ty;
        SHit h = yardSDF(q, mask);
        float3 n = yardNormal(q, mask, 0.02);
        float gl;
        float3 alb = yardAlbedo(h.mat, h.lp, n, h.ag, 0.08, gl);
        bounce += alb * (SUN * 0.95 * saturate(dot(n, L)) * 0.8 + SKY_AMB * 0.35);
    }
    bounce /= float(N);
    return vis / float(N);
}

// How much sky a field point sees past the lie of the land (1 = open), and the
// light the slopes in the way send back instead (`bounce`): a few cosine rays
// traced against the heightfield. Steep rays escape at once, so the cost is in
// the low rays that skim the ground.
float fieldTerrainVis(float3 w, float3 n, float rot, float jit, float t, out float3 bounce)
{
    bounce = float3(0.0, 0.0, 0.0);
    float3 L = sunWorld();
    float vis = 0.0;
    const int N = 3;
    for (int k = 0; k < N; k++)
    {
        float3 d = cosineDir(n, k, N, rot, jit);
        float tf = traceField(w + n * 0.05, d, 80.0);
        if (tf < 0.0) { vis += 1.0; continue; }
        float3 g = w + n * 0.05 + d * tf;
        float ndl = 0.56 * saturate(dot(terrainNormal(g.xz), L)) / L.y;
        bounce += meadowAlbedo(g.xz) * (SUN * ndl * cloudShadowW(g.xz, t) * meadowTops(g.z) + SKY_AMB * 0.42);
    }
    bounce /= float(N);
    return vis / float(N);
}

// Window-band glass: dark, with the sky reflected in the panes.
float3 glassColour(float3 n, float2 uv)
{
    float3 c = lerp(float3(0.03, 0.04, 0.06), float3(0.22, 0.32, 0.46), 0.15 + 0.25 * saturate(n.y + 0.3));
    return c * (0.75 + 0.5 * vnoise(uv * float2(3.0, 9.0)));
}

// Albedo of a structure surface; `glass` returns how much of it is a window pane.
// fp is the pixel's footprint in metres: drawn detail (board joints, ridges)
// thins out where it would crowd closer than a painter would draw it.
float3 yardAlbedo(int mat, float3 lp, float3 n, float ag, float fp, out float glass)
{
    glass = 0.0;
    float u = abs(n.x) > abs(n.z) ? lp.z : lp.x;   // across the face
    if (mat == M_PLANK || mat == M_DOOR || mat == M_DARK)
    {
        float bw = mat == M_DOOR ? 0.22 : 0.28;
        float board = floor(u / bw);
        float f = frac(u / bw);
        float seam = smoothstep(0.0, 0.05, f) * smoothstep(1.0, 0.95, f);
        // Not every joint is drawn, and fewer the smaller the boards are on screen.
        float drawn = step(lerp(0.35, 0.80, smoothstep(10.0, 4.0, bw / fp)), hash11(board * 5.3));
        seam = lerp(1.0, seam, drawn * smoothstep(2.5, 5.0, bw / fp));
        float tone = 0.88 + 0.24 * posterize(hash11(board * 1.73 + floor(lp.y / 3.1) * 7.1), 3.0);
        float grain = posterize(vnoise(float2(u * 6.0, lp.y * 0.8)), 3.0);
        float streak = posterize(vnoise(float2(u * 1.1, lp.y * 0.35 + 3.0)), 3.0);   // weather streaks from the eaves
        float3 base = mat == M_DOOR ? float3(0.40, 0.40, 0.45) : (mat == M_DARK ? float3(0.17, 0.15, 0.15) : float3(0.52, 0.49, 0.52));
        float3 c = base * tone * (0.95 + 0.08 * grain) * lerp(0.66, 1.0, seam) * lerp(0.82, 1.06, streak);
        return c * lerp(0.72, 1.0, smoothstep(0.0, 0.9, ag));          // splashed dark near the ground
    }
    if (mat == M_WOOD)
    {
        float grain = posterize(vnoise(float2(lp.x * 2.0 + lp.z * 2.0, lp.y * 4.0)), 3.0);
        return float3(0.27, 0.22, 0.18) * (0.82 + 0.30 * grain);
    }
    if (mat == M_RUST || mat == M_TIN)
    {
        float ridge = 0.5 + 0.5 * sin(u * 6.2831 / 0.13) * smoothstep(4.0, 8.0, 0.13 / fp);
        float patch = posterize(fbm(lp.xz * 0.35 + lp.y * 0.2, 3), 4.0);
        float3 c = mat == M_RUST
            ? lerp(float3(0.36, 0.20, 0.13), float3(0.24, 0.20, 0.19), smoothstep(0.35, 0.65, patch))
            : lerp(float3(0.34, 0.39, 0.45), float3(0.40, 0.27, 0.18), smoothstep(0.62, 0.80, patch));
        return c * (0.86 + 0.14 * ridge) * (0.94 + 0.12 * posterize(vnoise(lp.xz * 1.2), 3.0));
    }
    if (mat == M_CONC)
    {
        float streak = posterize(vnoise(float2(atan2(lp.z, lp.x) * 2.0 + lp.x * 0.6, lp.y * 0.4)), 3.0);
        return float3(0.58, 0.58, 0.56) * (0.86 + 0.18 * streak) * lerp(0.74, 1.0, smoothstep(0.0, 1.2, ag));
    }
    if (mat == M_STEEL)
    {
        float rust = smoothstep(0.55, 0.80, fbm(lp.xy * float2(0.8, 0.4) + lp.z, 3));
        return lerp(float3(0.36, 0.28, 0.30), float3(0.40, 0.22, 0.13), rust * 0.7);
    }
    if (mat == M_PANEL || mat == M_STAIR || mat == M_HOUSE)
    {
        // Window bands (corridor and stairways) or a pair of windows (house).
        float wy0 = mat == M_PANEL ? 6.85 : (mat == M_STAIR ? 0.95 : 1.05);
        float wy1 = mat == M_PANEL ? 7.95 : (mat == M_STAIR ? 2.20 : 2.15);
        float pitch = mat == M_HOUSE ? 2.2 : (mat == M_STAIR ? 0.95 : 1.45);
        float wu = mat == M_STAIR ? lp.x : u;
        float cell = frac(wu / pitch + 0.5);
        float inBand = step(wy0, lp.y) * step(lp.y, wy1);
        if (mat == M_HOUSE) inBand *= step(0.5, abs(n.z)) * step(abs(lp.x), 2.4);
        float pane = inBand * step(0.12, cell) * step(cell, 0.88);
        float frame = inBand * (1.0 - pane);
        float3 wall = mat == M_HOUSE ? float3(0.62, 0.62, 0.60) : float3(0.70, 0.68, 0.62);
        float seam = smoothstep(0.0, 0.03, frac(lp.y / 0.6)) * 0.12 + 0.88;
        float dirt = posterize(vnoise(float2(wu * 0.7, lp.y * 0.4)), 3.0);
        float3 c = wall * seam * (0.84 + 0.2 * dirt);
        c = lerp(c, float3(0.80, 0.80, 0.76), frame);
        glass = pane;
        return c;
    }
    if (mat == M_SIGN)
    {
        float2 a = abs(lp.xy);
        float border = step(0.30, max(a.x, a.y));
        float bar = step(abs(lp.y), 0.07) * step(a.x, 0.24);
        float3 c = float3(1.10, 0.95, 0.42);
        c = lerp(c, float3(0.10, 0.09, 0.08), max(border, bar));
        return lerp(c, float3(0.32, 0.26, 0.18), step(0.5, abs(n.y)));   // edges of the board
    }
    if (mat == M_BALLAST)
    {
        // Crushed stone: angular grey-brown chips, rust-stained under the rails,
        // darker with oil between them, weeds creeping in at the shoulders.
        float2 sp = lp.xz * float2(1.0, 1.0);
        // Painted as dabs: patches of light and dark stone, a few drawn gaps.
        float stones = posterize(vnoise(sp * 6.0) * 0.65 + vnoise(sp * 15.0) * 0.35, 3.0);
        float cells = worley2(sp * 9.0);
        float3 c = lerp(float3(0.22, 0.20, 0.18), float3(0.28, 0.24, 0.19), posterize(vnoise(sp * 1.5), 2.0)) * lerp(0.72, 1.12, stones);
        c *= lerp(0.82, 1.0, smoothstep(0.04, 0.16, cells));                           // gaps between the stones
        c = lerp(c, float3(0.30, 0.17, 0.10), smoothstep(0.25, 0.0, abs(abs(lp.x) - GAUGE_HALF)) * 0.45);
        c = lerp(c, float3(0.11, 0.09, 0.08), smoothstep(0.55, 0.0, abs(lp.x)) * 0.30);
        float weeds = smoothstep(0.55, 0.78, fbm(lp.xz * float2(0.6, 0.25) + 7.0, 3)) * smoothstep(1.2, 1.8, abs(lp.x));
        return lerp(c, float3(0.10, 0.19, 0.05), weeds * 0.8);
    }
    if (mat == M_SLEEPER)
    {
        // Weathered creosoted timber: grain along the sleeper, split ends, each one
        // its own shade of grey-brown.
        float id = floor(lp.z / 1.4);
        float grain = posterize(vnoise(float2(lp.x * 1.5, id * 7.0)), 2.0);
        float3 c = lerp(float3(0.17, 0.13, 0.10), float3(0.26, 0.23, 0.20), posterize(hash11(id + 3.1), 3.0));
        return c * (0.82 + 0.30 * grain) * lerp(0.80, 1.0, smoothstep(1.30, 1.15, abs(lp.x)));
    }
    if (mat == M_RAIL)
    {
        // Rust-brown sides; the running surface on top is worn to bright steel.
        float head = smoothstep(0.505, 0.515, lp.y);
        float rust = posterize(vnoise(float2(lp.z * 0.7, lp.x * 3.0)), 2.0);
        return lerp(float3(0.24, 0.12, 0.06) * (0.80 + 0.35 * rust), float3(0.70, 0.67, 0.62), head);
    }
    if (mat == M_PORC) return float3(0.74, 0.74, 0.71);
    return float3(0.44, 0.46, 0.47);   // M_METAL
}

// Ray-march the yard under pixel p; rgb premultiplied by coverage a. hitZ is the
// depth (metres) of what was hit, for ordering with the grass; < 0 if nothing.
float4 drawYard(float2 p, float aspect, float t, float px, out float hitZ)
{
    hitZ = -1.0;
    float3 ro = float3(0.0, EYE_M, 0.0);
    float3 rd = viewRay(p, aspect);
    float2 span;
    int mask = yardCull(ro, rd, 1e4, YARD_ALL, span);
    if (mask == 0) return float4(0, 0, 0, 0);
    float pw = px * SKY_TAN;                     // pixel size per metre of distance
    float tt = span.x;
    float best = 1e9;
    float tBest = tt;
    bool hit = false;
    bool sunk = false;
    for (int i = 0; i < 240 && tt < span.y; i++)
    {
        float3 q = ro + rd * tt;
        if (q.y < terrainH(q.xz) - 0.05) { sunk = true; break; }   // into the field: hidden
        float d = yardSDF(q, mask).d;
        float r = d / (pw * tt);
        if (r < best) { best = r; tBest = tt; }
        if (r < 0.2) { hit = true; break; }
        tt += d * 0.9;
    }
    if (!hit && best >= 1.8) return float4(0, 0, 0, 0);
    float alpha = hit ? 1.0 : saturate(1.0 - best);   // thin parts: the fraction of the pixel they cover
    // Silhouette line: rays that pass just outside an outline draw a fine line.
    float sil = hit ? 0.0 : (1.0 - smoothstep(0.8, 1.8, best)) * 0.6;

    float3 P = ro + rd * tBest;
    SHit h = yardSDF(P, mask);
    // The ballast bed's foot runs into the field: a near miss there is not a thin
    // part but the bed sinking into the ground (the spill decal covers it).
    if (!hit && sunk && h.mat == M_BALLAST) return float4(0, 0, 0, 0);
    float3 n = yardNormal(P, mask, max(0.004, 0.5 * pw * tBest));
    float3 L = sunWorld();
    float glass;
    float3 alb = yardAlbedo(h.mat, h.lp, n, h.ag, pw * tBest, glass);
    // Painted washes: broad, soft shifts of value and of warm and cool hue across
    // each surface, as a background painter lays them in, instead of fine noise.
    float2 wuv = float2(h.lp.x + h.lp.z, h.lp.y) * 0.45 + float(h.mat) * 3.1;
    float wash = fbm(wuv, 3);
    float hueW = fbm(wuv * 0.6 + 11.0, 2);
    alb *= (0.88 + 0.24 * wash) * lerp(float3(1.05, 1.0, 0.93), float3(0.95, 0.99, 1.06), smoothstep(0.3, 0.7, hueW));

    // Sun: soft shadows from the structures, the drifting cloud shadows (taken on
    // the ground below along the sun, where they are cast), a soft painted ramp.
    float sh = yardShadow(P + n * 0.06, YARD_ALL);
    float2 gb = P.xz - L.xz / L.y * h.ag;
    float vis = cloudShadowW(gb, t);
    float direct = saturate(dot(n, L)) * sh * vis;
    // A painted terminator: the light-shade boundary is firmed up and laid in
    // with short strokes, so it reads brushed rather than computed.
    float stroke = brush(p * 260.0, normalize(float2(0.35, 1.0)));
    float lit = lerp(direct, smoothstep(0.04, 0.24, direct + (stroke - 0.5) * 0.12), 0.85);
    // Fill: one-bounce GI - the sky (deep blue overhead, pale toward the horizon),
    // the warm green light off the sunlit meadow and the light off the walls
    // nearby, which is what lights the faces turned toward us, away from the sun.
    float rot = hash12(p / px + 3.7) * 6.2831;
    float jit = hash12(p / px + 9.1);
    float3 gi = yardIrradiance(P + n * 0.03, n, rot, jit, t);
    float3 light = SUN * 0.95 * lit + gi * 1.05;
    // Painted value steps: the light folds into half-stop bands with soft
    // edges, so a surface reads as a few laid-in tones rather than a gradient.
    float lumL = max(luminance(light), 1e-4);
    float xb = log2(lumL) * 2.0 + (stroke - 0.5) * 0.25;
    float lq = exp2((floor(xb) + smoothstep(0.25, 0.75, frac(xb))) * 0.5);
    light *= lerp(1.0, lq / lumL, 0.6);
    // Laid in with the brush: short strokes of flat colour, upright on walls
    // and posts, across on roofs and the ground, each a touch lighter or
    // darker, warmer or cooler.
    float2 dabDir = abs(n.y) > 0.6 ? normalize(float2(1.0, 0.18)) : normalize(float2(0.12, 1.0));
    float dab = paintDabs(p * 1080.0, dabDir);
    float3 c = alb * light;
    c *= (0.91 + 0.18 * dab) * lerp(float3(1.03, 1.0, 0.95), float3(0.97, 1.0, 1.04), frac(dab * 7.31));
    // Mirror ray for the glass, the worn rail heads and the metal: the sky or
    // whatever stands opposite, weighted by Fresnel.
    float F0 = glass > 0.0 ? 0.04 : (h.mat == M_RAIL ? 0.35 * smoothstep(0.505, 0.515, h.lp.y) : (h.mat == M_METAL || h.mat == M_TIN ? 0.06 : 0.0));
    float3 gc = glassColour(n, h.lp.xy) * (0.75 + 0.25 * vis);
    if (F0 > 0.0)
    {
        float3 R = reflect(rd, n);
        float F = F0 + (1.0 - F0) * pow(1.0 - saturate(dot(n, -rd)), 5.0);
        float3 refl = traceRadiance(P + n * 0.03, R, t) + SUN * 6.0 * pow(saturate(dot(R, L)), 60.0) * sh * vis;
        gc += refl * F * 0.9;
        if (glass <= 0.0) c = lerp(c, refl, F * (h.mat == M_RAIL ? 0.8 : 0.35));
    }
    c = lerp(c, gc, glass);

    // Line art. A normal taken over ~2 px differs from the surface normal only
    // near an edge or a crease, which marks where a painter draws a line: a
    // dark line (a deeper, slightly violet shade of the local colour) in the
    // creases and on the shaded edges, and a light line where a convex edge
    // catches the sun. The stroke noise makes the line's weight uneven, as by hand.
    float eL = max(0.02, 2.0 * pw * tBest);
    float3 nL = yardNormal(P, mask, eL);
    float edge = saturate((1.0 - dot(n, nL)) * 7.0) * (0.65 + 0.7 * stroke);
    float convex = smoothstep(0.55, 0.85, yardSDF(P + nL * eL, mask).d / eL);
    float edgeLit = convex * saturate(dot(nL, L) * 2.5) * sh * vis;
    float3 lineC = c * lerp(float3(0.50, 0.47, 0.56), float3(1.32, 1.27, 1.14), edgeLit);
    c = lerp(c, lineC, saturate(edge) * 0.8);

    // Grass grows up around the foot of everything standing in the field.
    float blades = vnoise(float2(p.x / px * 0.45, 2.0)) * 0.6 + vnoise(float2(p.x / px * 1.3, 5.0)) * 0.4;
    bool onTrack = h.mat == M_BALLAST || h.mat == M_SLEEPER || h.mat == M_RAIL || (h.mat == M_METAL && h.ag < 0.6)
                || (h.mat == M_CONC && h.ag < 1.0 && P.x > 30.0);   // nor on the platform's concrete base
    float foot = onTrack ? 1.0 : smoothstep(0.0, 0.12, h.ag - 0.42 * blades);
    if (onTrack) sil = 0.0;   // the bed and rails are lined by their creases

    // Aerial perspective by the true distance (the field's own haze grows
    // toward the skyline faster, standing in for the kilometres beyond).
    float hz = 0.55 * (1.0 - exp(-tBest / 900.0));
    float3 silC = applyHaze(c * float3(0.46, 0.43, 0.52), hz);
    c = applyHaze(c, hz);
    hitZ = P.z;
    float a = (alpha + sil * (1.0 - alpha)) * foot;
    return float4((c * alpha * (1.0 - sil) + silC * sil) * foot, a);
}

// --- Wires --------------------------------------------------------------------

// Attachment points: three conductors at the insulators of pole i.
float3 wirePoint(int i, int w)
{
    float3 b = onGround(i < 4 ? POLE_POS[i] : (i == 4 ? float3(-50.0, 0.0, 34.0) : float3(55.0, 0.0, 262.0)));
    float H = i < 4 ? POLE_H[i] : (i == 4 ? 13.0 : 9.0);
    float x = w == 0 ? -0.9 : (w == 1 ? 0.9 : -0.7);
    float y = w < 2 ? H - 0.24 : H - 1.04;
    return b + float3(x, y, 0.0);
}

// Sagging wires between the poles; skipped where a nearer structure covers them.
float3 drawWires(float3 col, float2 p, float aspect, float px, float yardZ)
{
    for (int s = 0; s < 3; s++)
    {
        int ia = s == 0 ? 2 : (s == 1 ? 1 : (s == 2 ? 0 : 3));
        int ib = s == 0 ? 1 : (s == 1 ? 0 : (s == 2 ? 4 : 5));
        for (int w = 0; w < 3; w++)
        {
            float3 a = wirePoint(ia, w);
            float3 b = wirePoint(ib, w);
            float3 m = (a + b) * 0.5 - float3(0.0, 0.012 * length(b - a), 0.0);
            float2 sa = projectWorld(a, aspect);
            float2 sb = projectWorld(b, aspect);
            float2 sm = projectWorld(m, aspect);
            float2 cc = 2.0 * sm - 0.5 * (sa + sb);
            float2 lo = min(min(sa, sb), cc) - 0.01;
            float2 hi = max(max(sa, sb), cc) + 0.01;
            if (any(p < lo) || any(p > hi)) continue;
            float best = 1e9;
            float bt = 0.0;
            float2 prev = sa;
            for (int k = 1; k <= 24; k++)
            {
                float u = float(k) / 24.0;
                float2 q = lerp(lerp(sa, cc, u), lerp(cc, sb, u), u);
                float2 pa = p - prev;
                float2 ba = q - prev;
                float hh = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-12));
                float d = length(pa - ba * hh);
                if (d < best) { best = d; bt = (float(k) - 1.0 + hh) / 24.0; }
                prev = q;
            }
            float zw = lerp(a.z, b.z, bt);
            if (yardZ > 0.0 && zw > yardZ + 1.0) continue;
            float ws = 0.020 / (zw * SKY_TAN);               // wire diameter on screen
            float cov = saturate(1.0 - best / (0.5 * max(ws, px) + 0.5 * px)) * saturate(ws / px * 1.4 + 0.12);
            float3 wc = applyHaze(float3(0.05, 0.05, 0.06), 0.55 * (1.0 - exp(-zw / 900.0)));
            col = lerp(col, wc, cov * 0.9);
        }
    }
    return col;
}

// --- Bushes -------------------------------------------------------------------

// Shrubs (x, base y, z, height in metres), drawn as low round trees.
static const int BUSH_N = 4;
static const float4 BUSHES[4] = {
    float4(-27.0, 0.0, 80.0, 2.8), float4(-12.0, 0.0, 192.0, 2.2), float4(5.0, 0.0, 206.0, 1.8), float4(-44.0, 0.0, 218.0, 2.4)
};

// The bush covering pixel p (nearest first), or -1.
int bushAt(float2 p, float aspect, out float2 base, out float hs)
{
    int found = -1;
    float bestZ = 1e9;
    base = float2(0.0, 0.0);
    hs = 0.0;
    for (int i = 0; i < BUSH_N; i++)
    {
        float4 b = BUSHES[i];
        float2 sb = projectWorld(onGround(b.xyz), aspect);
        float h = b.w / (b.z * SKY_TAN) / 0.85;
        float2 q = (p - sb) / h;
        if (q.y < -0.08 || q.y > 1.3 || abs(q.x) > 1.4) continue;
        if (b.z < bestZ) { bestZ = b.z; found = i; base = sb; hs = h; }
    }
    return found;
}

// Smooth lit colour of the meadow at field point w (no grass strokes), before
// haze; the grass takes its colour from it, so blades and ground always match.
// `haze` returns the aerial perspective there, `light` the light falling on it.
float3 groundShade(float3 w, float t, out float haze, out float3 light)
{
    float v = fieldV(w.z);
    float2 g = fieldPseudo(w.xz);

    float3 albedo = meadowAlbedo(w.xz);

    // Sun, drifting cloud shadows and the shadows of the structures.
    float vis = cloudShadowW(w.xz, t) * yardGroundShadow(w);
    // The lie of the land, plus finer rolls in the grass mat: slopes facing the
    // sun are brighter, the far sides dimmer.
    float2 rq = g * float2(0.045, 0.030) + 5.0;
    float r0 = fbm(rq, 3);
    float rx = fbm(rq + float2(0.05, 0.0), 3) - r0;
    float rz = fbm(rq + float2(0.0, 0.05), 3) - r0;
    float3 n = terrainNormal(w.xz);
    float3 rn = normalize(float3(n.x - rx * 8.0, n.y, n.z - rz * 8.0));
    float3 L = sunWorld();
    float ndl = 0.56 * saturate(dot(rn, L)) / L.y + 0.04 * r0;
    float ao = lerp(0.74, 1.0, smoothstep(0.35, 0.80, v));
    // Ray-traced: the sky the structures hide, and the light their walls return.
    float3 wallBounce;
    float3 landBounce;
    float rot = hash12(w.xz * 41.3) * 6.2831;
    float jit = hash12(w.xz * 17.9 + 3.0);
    float skyVis = fieldSkyVis(w, rot, jit, t, wallBounce);
    float landVis = fieldTerrainVis(w, n, rot + 1.7, jit, t, landBounce);
    float3 sunL = SUN * ndl * vis * ao;
    float3 skyL = (SKY_AMB * 0.42 * skyVis * landVis + wallBounce + landBounce) * ao;
    light = sunL + skyL;   // on bare ground (the ballast spill)
    float3 c = albedo * (sunL * meadowTops(w.z) + skyL) + meadowSheen(w.z) * skyVis;

    // Luminous haze over the far field (the light-filled middle distance of the painting).
    c += MEADOW_GLOW * meadowGlow(v) * vis;
    haze = fieldHazeAt(w.z);
    return c;
}

// How much of the sunlit top of the grass mat a view at distance z sees: close
// by the eye looks down into the mat, between the blades, at the shaded growth
// inside it (lit only by the sky, so cool); at a glance far off only the sunlit
// tops show. Hence the darker, teal foreground under a bright middle distance.
float meadowTops(float z) { return lerp(0.20, 1.0, 1.0 - exp(-z / 70.0)); }

// Sunlight through the blades: seen from above, close by, the shaded growth
// inside the mat glows a translucent yellow-green.
float3 meadowSheen(float z) { return float3(0.026, 0.046, 0.020) * (1.0 - smoothstep(10.0, 120.0, z)); }

// Light-filled air over the middle and far field: the sunlit meadow's own
// light scattered toward the eye, pale and warm.
static const float3 MEADOW_GLOW = float3(0.50, 0.48, 0.24) * 0.42;
float meadowGlow(float v) { return smoothstep(0.40, 0.97, v); }

// Meadow albedo at world (x, z), after the painting: broad patches of warm
// yellow-green, fresh green and teal, pale sun-bleached streaks and worn
// patches, finer mottling; toward the skyline it pales to a light yellow-green.
float3 meadowAlbedo(float2 g)
{
    float v = fieldV(g.y);
    float2 q = fieldPseudo(g);
    // Patches at two scales (~90 m and ~20 m) so both the near and the far
    // field show them.
    // Near the camera a patch would fill the whole width of the frame and read
    // as a band, so the patches fade in with distance (an even mottle up close).
    float pf = smoothstep(30.0, 90.0, g.y);
    float big = lerp(0.52, fbm(g * 0.011 + 3.1, 4) * 0.6 + fbm(g * 0.045 + 8.3, 4) * 0.4, pf);
    float mid = fbm(q * float2(0.16, 0.09) + 2.0, 4);
    float streak = fbm(float2(g.x * 0.030, g.y * 0.10) + 7.0, 3);
    float3 a = lerp(float3(0.085, 0.180, 0.050), float3(0.195, 0.290, 0.060), smoothstep(0.40, 0.62, big));
    a = lerp(a, float3(0.055, 0.150, 0.075), smoothstep(0.44, 0.30, big) * 0.75);
    a *= 0.84 + 0.32 * mid;
    a = lerp(a, float3(0.270, 0.330, 0.120), smoothstep(0.60, 0.74, streak) * 0.50 * lerp(0.4, 1.0, pf));
    a = lerp(a, float3(0.215, 0.300, 0.085), smoothstep(0.55, 0.95, v));
    return a;
}

// The lit meadow colour at field point (x, z) without the structures' shadows,
// hazed for its distance: what a grass blade rooted there is painted with.
float3 groundAtRoot(float2 g, float t)
{
    float3 w = float3(g.x, terrainH(g), g.y);
    float v = fieldV(g.y);
    float2 q = fieldPseudo(g);
    float3 albedo = meadowAlbedo(g);
    float vis = cloudShadowW(g, t);
    float3 L = sunWorld();
    float ndl = 0.56 * saturate(dot(terrainNormal(g), L)) / L.y;
    float ao = lerp(0.74, 1.0, smoothstep(0.35, 0.80, v));
    float3 c = albedo * (SUN * ndl * vis * ao * meadowTops(g.y) + SKY_AMB * 0.42 * ao) + meadowSheen(g.y);
    c += MEADOW_GLOW * meadowGlow(v) * vis;
    return applyHaze(c, fieldHazeAt(g.y));
}

// The field seen at pixel p (w: where its ray meets the field).
// c, haze, light: groundShade at w.
float3 drawGround(float3 col, float2 p, float3 w, float aspect, float t, float px, float3 c, float haze, float3 light)
{
    if (w.z < 0.0) return col;
    float v = fieldV(w.z);
    float2 g = fieldPseudo(w.xz);
    float x = g.x;
    float z = g.y;
    // Painted grass strokes that lean with the breeze, fading with distance.
    float detail = saturate(1.0 - z / 25.0);
    float wind = windField(x * 0.35 + z * 0.1, t);
    float2 sp = float2(p.x * 38.0 + wind * 0.3 * detail, p.y * 260.0 / (0.4 + v));
    float stroke = vnoise(sp) * 0.55 + 0.45 * vnoise(sp * float2(2.3, 1.7) + 4.0);
    stroke = lerp(stroke, vnoise(float2(p.x * 300.0, p.y * 90.0)), 0.35 * detail);
    c *= lerp(1.0, 0.70 + 0.60 * stroke, detail * 0.75) * lerp(0.80, 1.0, stroke);

    // Gust sheen rolling over the field.
    float vis = cloudShadowW(w.xz, t);
    float wave = sin(x * 0.55 + z * 0.22 - t * 0.9 + fbm(g * 0.12 + float2(-t * 0.08, 0.0), 3) * 5.0);
    float sheen = smoothstep(0.35, 1.0, wave) * windField(x * 0.3 + z * 0.15, t) * detail * (0.3 + 0.7 * v);
    c += float3(0.30, 0.34, 0.16) * sheen * 0.35 * vis;
    // Ballast spilled round the track bed.
    float3 rd = viewRay(p, aspect);
    float3 n = terrainNormal(w.xz);
    float2 fp = float2(w.z * SKY_TAN * px, w.z * SKY_TAN * px / max(abs(dot(rd, n)), 0.01));
    float4 td = trackDecal(w.xz, fp);
    c = lerp(c, td.rgb * light, td.a);
    return lerp(col, applyHaze(c, haze), 1.0);
}

float2 hash22(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

// 2D Worley F1 distance, ~[0, 1].
float worley2(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float md = 1.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
        {
            float2 o = float2(float(x), float(y));
            float2 r = o + hash22(i + o) - f;
            md = min(md, dot(r, r));
        }
    return sqrt(md);
}

// A volumetric tree, ray-marched like the clouds so it has real depth.
// Tree space is in units of the tree's height: x right, y up, z toward the camera.
//   * skeleton grown in 3D: a trunk forks into limbs spreading all round (some
//     toward us, some away) plus a leader, and each limb splits into two twigs;
//   * foliage: 3D leaf masses on the limb ends and twigs, eroded by 3D Worley
//     noise into leaf clusters; the cluster size follows the tree's size on
//     screen, so a far tree shows a few big clumps rather than a mass of leaves;
//   * light: at the leaf surface we march toward the sun through the foliage
//     (real self-shadowing - the far side and the inside of the crown are dark),
//     3D normals and occlusion, translucency where light passes through thin
//     leaves, all pushed through a painted three-tone ramp;
//   * wood is 3D too: hidden behind front leaves, glimpsed through gaps, and
//     shaded by the crown above it.
static const int TREE_LIMBS = 5;
static const int TREE_TIPS  = 21;
static const int TREE_SEGS  = 23;   // 3 trunk + 2 per limb (curved) + 2 twigs per limb

// Trunk centre line: a gently curving, slightly leaning stem.
float3 trunkAt(float y, float seed, float lean)
{
    return float3(lean * y / 0.62 + 0.012 * sin(y * 9.0 + seed * 3.0), y, 0.010 * sin(y * 7.0 + seed));
}
float trunkRadius(float y) { return lerp(0.024, 0.008, saturate(y / 0.62)); }

// Segments carry their radius at each end (xyz, r).
void buildTree(float seed, out float4 tips[TREE_TIPS], out float4 segA[TREE_SEGS], out float4 segB[TREE_SEGS])
{
    float spread = lerp(0.90, 1.25, hash11(seed * 1.11));
    float lean = (hash11(seed * 3.37) - 0.5) * 0.08;
    const float TOP = 0.62;
    // Trunk in three pieces, tapering continuously.
    for (int k = 0; k < 3; k++)
    {
        float y0 = TOP * float(k) / 3.0;
        float y1 = TOP * float(k + 1) / 3.0;
        segA[k] = float4(trunkAt(y0, seed, lean), trunkRadius(y0));
        segB[k] = float4(trunkAt(y1, seed, lean), trunkRadius(y1));
    }
    int nt = 0;
    for (int l = 0; l < TREE_LIMBS; l++)
    {
        float fl = float(l);
        // Limbs leave the trunk at different heights; higher ones are more upright.
        float ya = lerp(0.20, 0.46, (fl + hash11(seed + fl * 0.7)) / float(TREE_LIMBS));
        float az = fl * 2.39996 + seed * 0.37;   // golden-angle phyllotaxis
        float el = lerp(1.15, 0.65, ya / 0.46) + (hash11(seed + fl * 2.7) - 0.5) * 0.25;
        float3 dir = float3(sin(el) * cos(az) * spread, cos(el), sin(el) * sin(az) * 0.85);
        float len = lerp(0.30, 0.40, hash11(seed + fl * 3.3)) * lerp(1.1, 0.8, ya / 0.46);
        float3 P0 = trunkAt(ya, seed, lean);
        // Curved limb: reaches out, then bends upward toward the light.
        float3 P1 = P0 + float3(dir.x, dir.y * 0.6, dir.z) * len * 0.55;
        float3 P2 = P0 + dir * len + float3(0.0, 0.10 * len / 0.35, 0.0);
        float3 M = 0.25 * P0 + 0.5 * P1 + 0.25 * P2;
        float r0 = trunkRadius(ya) * 0.62;
        float rm = r0 * 0.62;
        float r2 = 0.0045;
        segA[3 + l * 2] = float4(P0, r0);
        segB[3 + l * 2] = float4(M, rm);
        segA[4 + l * 2] = float4(M, rm);
        segB[4 + l * 2] = float4(P2, r2);
        tips[nt++] = float4(P2, lerp(0.15, 0.19, hash11(seed + fl * 4.1)));
        // Foliage also clothes the limb along its outer half.
        tips[nt++] = float4(M + float3(dir.x * 0.05, 0.06, dir.z * 0.05), lerp(0.13, 0.16, hash11(seed + fl * 9.1)));
        for (int k = 0; k < 2; k++)
        {
            float fk = float(k);
            float3 jit = float3(hash11(seed + fl * 5.3 + fk), hash11(seed + fl * 6.1 + fk * 2.0), hash11(seed + fl * 7.9 + fk * 3.0)) - 0.5;
            float3 d2 = normalize(dir + jit * 1.1 + float3(0.0, 0.45, 0.0));
            float3 T2 = P2 - dir * len * (0.15 + 0.2 * fk) + d2 * lerp(0.10, 0.18, hash11(seed + fl * 8.7 + fk * 1.3));
            float3 S2 = lerp(M, P2, 0.5 + 0.3 * fk);
            segA[3 + TREE_LIMBS * 2 + l * 2 + k] = float4(S2, 0.0045);
            segB[3 + TREE_LIMBS * 2 + l * 2 + k] = float4(T2, 0.0020);
            tips[nt++] = float4(T2, lerp(0.12, 0.15, hash11(seed + fl * 9.9 + fk * 2.3)));
        }
    }
    // Crown top over the leader.
    tips[nt] = float4(trunkAt(TOP, seed, lean) + float3(0.0, 0.06, 0.0), 0.16);
}

// A shrub: three rings of leaf masses hugging the ground, wider than deep.
void buildBush(float seed, out float4 tips[TREE_TIPS])
{
    for (int i = 0; i < TREE_TIPS; i++)
    {
        float fi = float(i);
        int ring = i < 9 ? 0 : (i < 16 ? 1 : 2);
        float a = fi * 2.39996 + seed * 0.71;
        float rr = ring == 0 ? 0.62 : (ring == 1 ? 0.38 : 0.14);
        float y = ring == 0 ? 0.24 : (ring == 1 ? 0.50 : 0.70);
        float j = hash11(seed + fi * 1.7);
        tips[i] = float4(cos(a) * rr * 1.25 * (0.85 + 0.3 * j), y + (j - 0.5) * 0.12, sin(a) * rr * 0.85,
                         lerp(0.24, 0.30, hash11(seed + fi * 3.1)));
    }
}

float treeCoarse(float3 p, float4 tips[TREE_TIPS])
{
    float s = 0.0;
    for (int i = 0; i < TREE_TIPS; i++)
    {
        float3 d = p - tips[i].xyz;
        s += exp(-dot(d, d) / (tips[i].w * tips[i].w));
    }
    return s;
}

// Leaf field: > 0.5 inside the foliage.
float treeLeaf(float3 p, float4 tips[TREE_TIPS], float seed, float freq, out float coarse)
{
    coarse = treeCoarse(p, tips);
    if (coarse < 0.12) return coarse - 0.6;
    // Irregular erosion: a few larger hollows and ragged edges, not round puffs;
    // leaf-level detail comes from the individual leaves drawn on the surface.
    float wv = worley3(p * freq * 0.7 + seed);
    float n = fbm3(p * freq * 0.6 + seed * 2.0, 3);
    float m = fbm3(p * freq * 1.8 + seed * 5.0, 2);
    return coarse * (0.80 + 0.30 * n) + (0.46 - wv) * 0.55 + (n - 0.5) * 0.70 + (m - 0.5) * 0.30;
}

// Sunlight reaching p through the foliage (1 = unshadowed).
float treeSunVis(float3 p, float3 L, float4 tips[TREE_TIPS], float seed, float freq)
{
    float od = 0.0;
    float stepL = 0.03;
    float3 x = p;
    for (int j = 0; j < 6; j++)
    {
        x += L * stepL;
        float cc;
        od += saturate(treeLeaf(x, tips, seed, freq, cc) - 0.35) * stepL;
        stepL *= 1.55;
    }
    return exp(-od * 20.0);
}

float3 drawTree(float3 col, float2 p, float2 base, float h, float seed, float haze, float t, float px, bool bush)
{
    float2 q = (p - base) / h;
    if (q.y < -0.06 || q.y > 1.30 || abs(q.x) > (bush ? 1.35 : 0.95)) return col;
    float aa = px / h;
    // The scene sun, to the right and beyond the tree: strong side modelling, rim-lit.
    float3 L = normalize(float3(0.74, 0.46, -0.48));   // the scene sun (tree space: z toward the camera)
    float hue = hash11(seed * 5.53);

    // Ground shadow under the crown, cast toward the lower left.
    float shE = length((q - float2(bush ? -0.25 : -0.12, -0.012)) / (bush ? float2(0.95, 0.07) : float2(0.45, 0.045)));
    col *= lerp(0.66, 1.0, smoothstep(0.5, 1.1, shE));

    // Breeze: the crown sways, more at the top.
    float w = windField(base.x * 3.0, t);
    float sway = (0.010 + 0.010 * w) * sin(t * 0.8 + seed) + 0.003 * sin(t * 2.3 + seed * 3.0);
    float2 qc = q - float2(sway * saturate(q.y) * saturate(q.y), 0.0);

    float4 tips[TREE_TIPS];
    float4 segA[TREE_SEGS];
    float4 segB[TREE_SEGS];
    buildTree(seed, tips, segA, segB);
    if (bush) buildBush(seed, tips);

    // Leaf clusters stay a similar size on screen: a far tree shows a few big clumps.
    float freq = 17.0 * clamp(h / 0.105, 0.65, 1.0);

    // March the foliage front to back.
    const int STEPS = 40;
    float Z0 = bush ? 0.95 : 0.75;
    float Z1 = -Z0;
    float dz = (Z0 - Z1) / float(STEPS);
    float jitter = hash12(p * 4099.0);
    float kMax = -1.0;
    float zMax = 0.0;
    float hitZ = -1e3;
    float prevK = -1.0;
    float prevZ = Z0;
    for (int i = 0; i < STEPS; i++)
    {
        float z = Z0 - (float(i) + jitter) * dz;
        float cc;
        float k = treeLeaf(float3(qc, z), tips, seed, freq, cc);
        if (k > kMax) { kMax = k; zMax = z; }
        if (k > 0.5)
        {
            // Refine the crossing.
            float za = prevZ;
            float zb = z;
            for (int r = 0; r < 4; r++)
            {
                float zm = 0.5 * (za + zb);
                float c2;
                if (treeLeaf(float3(qc, zm), tips, seed, freq, c2) > 0.5) zb = zm; else za = zm;
            }
            hitZ = zb;
            break;
        }
        prevK = k;
        prevZ = z;
    }
    float edgeW = clamp(aa * freq * 0.9, 0.01, 0.25);
    float core = smoothstep(0.5 - edgeW, 0.5 + edgeW * 0.3, kMax);
    if (hitZ < -100.0) hitZ = zMax;

    // Individual leaves: pointed ovals on a jittered grid, a constant size on
    // screen (~8 px at 1440p), each with its own direction and tilt. They make the
    // crown's outline (leaves sticking out past the foliage mass) and give every
    // leaf its own light inside it; the gaps between leaves are dark.
    float cellS = max(0.80 / freq, aa * 7.0);
    float2 lc = qc / cellS;
    float2 li = floor(lc);
    float leafCov = 0.0;
    float leafOrder = -1.0;
    float leafTilt = 0.0;
    float leafAcross = 1.0;
    float leafAlong = 0.0;
    float2 leafDir = float2(0, 1);
    float pxCell = aa / cellS;
    for (int j = -1; j <= 1; j++)
        for (int i = -1; i <= 1; i++)
        {
            float2 cid = li + float2(float(i), float(j));
            float2 rnd = hash22(cid + seed * 1.31);
            float2 ctr = cid + 0.5 + (rnd - 0.5) * 0.85
                       + float2(0.06, 0.03) * w * sin(t * (1.7 + 1.3 * rnd.x) + rnd.y * 30.0);
            // Leaves droop and point away from the crown centre, with scatter.
            float2 outward = normalize(ctr * cellS - float2(0.0, bush ? 0.40 : 0.62) + 1e-4);
            float ang = atan2(outward.y, outward.x) - 0.6 + (hash12(cid * 1.73 + seed) - 0.5) * 2.6;
            float2 dv = float2(cos(ang), sin(ang));
            float2 d = lc - ctr;
            float len = 0.80 + 0.35 * rnd.x;
            float u = dot(d, dv) / len;
            float v = dot(d, float2(-dv.y, dv.x));
            float wid = 0.36 * len * sqrt(saturate(1.0 - u * u)) * (1.0 - 0.30 * u);
            float sd = min(wid - abs(v), (1.0 - abs(u)) * len);
            float cov = saturate(sd / pxCell + 0.5);
            float order = hash12(cid * 3.17 + seed);
            if (cov > 0.0 && order > leafOrder)
            {
                leafOrder = order;
                leafCov = cov;
                // Leaves flutter in the breeze: each one rocks at its own rate, more in gusts.
                leafTilt = rnd.y - 0.5 + (0.18 + 0.30 * w) * sin(t * (2.2 + 2.5 * order) + order * 40.0);
                leafAcross = abs(v) / max(wid, 1e-3);
                leafAlong = u;
                leafDir = dv;
            }
        }
    // Fringe: leaves only grow where there is foliage just behind them.
    float fringe = leafCov * smoothstep(0.26, 0.44, kMax);
    float cover = max(core, fringe);

    // Wood: nearest projected limb, with its front surface depth.
    float dWood = 1e3;
    float3 woodP = float3(0, 0, 0);
    float3 woodN = float3(0, 0, 1);
    for (int i = 0; i < TREE_SEGS; i++)
    {
        float3 A = segA[i].xyz;
        float3 B = segB[i].xyz;
        float2 pa = qc - A.xy;
        float2 ba = B.xy - A.xy;
        float hh = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
        float rad = lerp(segA[i].w, segB[i].w, hh);
        float2 off = pa - ba * hh;
        float di = length(off) - rad;
        if (di < dWood)
        {
            dWood = di;
            float sxy = saturate(length(off) / max(rad, 1e-4));
            woodN = normalize(float3(off / max(rad, 1e-4), sqrt(max(1.0 - sxy * sxy, 0.0))));
            woodP = float3(qc, lerp(A.z, B.z, hh) + woodN.z * rad);
        }
    }
    float wood = bush ? 0.0 : saturate(-dWood / aa + 0.5);
    // Grass grows up around the foot of the trunk.
    wood *= smoothstep(0.0, 0.035, q.y - 0.012 + (vnoise(float2(q.x * 260.0, 3.0)) - 0.5) * 0.030);
    bool woodInFront = woodP.z > hitZ || cover <= 0.0;

    float3 c = col;
    float a = 0.0;
    if (wood > 0.0)
    {
        float vis = treeSunVis(woodP, L, tips, seed, freq);
        // Bark: vertical fissures, warm brown-grey on the lit side, cool and dark in shade.
        float fiss = vnoise(float2(woodN.x * 5.0 + woodP.x * 40.0, woodP.y * 220.0));
        float barkTex = 0.70 + 0.45 * fiss + 0.15 * vnoise(woodP.xy * 400.0);
        float ndlW = saturate(dot(woodN, L));
        float3 bark = lerp(float3(0.040, 0.034, 0.030), float3(0.062, 0.044, 0.030), smoothstep(0.1, 0.6, ndlW)) * barkTex;
        float3 wc = bark * (SUN * 0.85 * smoothstep(0.05, 0.45, ndlW) * vis + float3(0.18, 0.22, 0.22) * 0.85 * lerp(0.6, 1.0, woodN.y * 0.5 + 0.5));
        c = lerp(c, wc, wood);
        a = wood;
    }

    if (cover > 0.0 && !(woodInFront && wood > 0.5))
    {
        float3 P = float3(qc, hitZ);
        // Normals: the crown's big form blended with the leaf clusters'.
        float e = 0.35 / freq;
        float c0;
        float cx1; float cx2; float cy1; float cy2; float cz1; float cz2;
        float kx = treeLeaf(P + float3(e, 0, 0), tips, seed, freq, cx1) - treeLeaf(P - float3(e, 0, 0), tips, seed, freq, cx2);
        float ky = treeLeaf(P + float3(0, e, 0), tips, seed, freq, cy1) - treeLeaf(P - float3(0, e, 0), tips, seed, freq, cy2);
        float kz = treeLeaf(P + float3(0, 0, e), tips, seed, freq, cz1) - treeLeaf(P - float3(0, 0, e), tips, seed, freq, cz2);
        float3 nf = -normalize(float3(kx, ky, kz) + 1e-5);
        float3 nc = -normalize(float3(cx1 - cx2, cy1 - cy2, cz1 - cz2) + 1e-5);
        float3 n = normalize(nc * 0.45 + nf * 0.55);
        // Each leaf is tilted its own way.
        n = normalize(n + float3(leafDir * leafTilt * 0.9, leafTilt * 0.3) * leafCov);

        float vis = treeSunVis(P + n * 0.01, L, tips, seed, freq);
        float coarseP = treeCoarse(P, tips);
        float ao = lerp(1.0, 0.35, smoothstep(0.5, 1.5, coarseP)) * lerp(0.65, 1.0, saturate(n.y * 0.5 + 0.5));
        float direct = saturate(dot(n, L)) * vis;

        // Painted three-tone ramp: shade, mid, light.
        float lit = smoothstep(0.06, 0.26, direct);
        float hi = smoothstep(0.40, 0.65, direct);
        float hueN = saturate(hue * 0.6 + fbm(qc * 3.5 + seed * 4.0, 2) * 0.8 - 0.2);
        float3 litA = lerp(float3(0.175, 0.245, 0.045), float3(0.130, 0.225, 0.055), hueN);
        float3 midA = lerp(float3(0.070, 0.140, 0.040), float3(0.055, 0.130, 0.050), hueN);
        float3 shdA = lerp(float3(0.032, 0.082, 0.048), float3(0.026, 0.076, 0.058), hueN);
        float3 albedo = lerp(shdA, lerp(midA, litA, hi), lit);
        albedo *= 0.88 + 0.24 * leafOrder;
        // Leaf midrib and a lighter edge on sunlit leaves.
        albedo *= lerp(1.0, 0.86, (1.0 - smoothstep(0.0, 0.18, leafAcross)) * leafCov * lit);
        albedo = lerp(albedo, albedo * 1.18, smoothstep(0.65, 1.0, leafAcross) * leafCov * hi);
        // Gaps between leaves look into the darker inside of the crown.
        albedo = lerp(albedo * 0.55, albedo, max(leafCov, 1.0 - core));
        // Sky light: each cluster's sky-facing side is brighter, so the leaf masses
        // stay readable inside the shadow.
        float skyFace = saturate(nf.y * 0.5 + 0.5) * 0.7 + saturate(-nf.x * 0.5 + 0.5) * 0.3;
        float leafGrain = vnoise(qc * freq * 6.0 + seed * 5.0);
        float3 lc3 = albedo * (SUN * lerp(0.15, 1.0, lit) * lerp(0.6, 1.0, hi) * vis * (0.85 + 0.3 * leafGrain)
                               + float3(0.18, 0.31, 0.30) * 1.25 * ao * lerp(0.55, 1.25, skyFace));
        // Light through thin leaves: the sunward edge of the crown glows.
        float thin = 1.0 - smoothstep(0.35, 1.0, coarseP);
        lc3 += SUN * float3(0.05, 0.08, 0.02) * thin * vis * (1.0 - lit * 0.5);
        c = lerp(c, lc3, cover);
        a = max(a, cover);
    }
    if (a <= 0.0) return col;
    return lerp(col, applyHaze(c, haze), a);
}

// ---------------------------------------------------------------------------
// Foreground grass
// ---------------------------------------------------------------------------

struct GrassLayer
{
    float d0;         // near edge: the field's depth below the horizon (flat ground)
    float d1;         // far edge
    float height;     // nominal leaf screen length at the near edge
    float cellW;      // horizontal cell size
    float width;      // leaf half-width at its widest
    float depth;      // 0 = nearest .. 1 = far; thins the blades out
    float seed;
};

static const int BLADES_PER_CELL = 6;
static const int GRASS_LAYERS = 19;

// Grass height in metres: lush on the bank in front, summer-short beyond.
float grassM(float z) { return 0.26; }

// Screen y of the field at (x, z).
float fieldY(float x, float z) { return HORIZON + (terrainH(float2(x, z)) - EYE_M) / (z * SKY_TAN); }

// Painted grass: flat strokes in the meadow's own colour (`ground`, the lit field
// colour behind the pixel) - darker at the root, lighter toward the tip, a warm
// light on sunlit tips - with no per-blade 3D shading. The blades root on the
// terrain; only those rooted between zRange.x and zRange.y metres are drawn.
float3 drawGrassLayer(float3 col, float2 p, GrassLayer gl, float3 ground, float haze, float2 zRange,
                      float aspect, float t, float px)
{
    float zNear = EYE_M / (gl.d0 * SKY_TAN);
    float zFar = EYE_M / (gl.d1 * SKY_TAN);
    if (zFar < zRange.x || zNear > zRange.y) return col;
    float hiZ = zNear < 40.0 ? 3.4 : (zNear < 330.0 ? 7.5 : 22.0);
    if (p.y < HORIZON + (-1.5 - EYE_M) / (zNear * SKY_TAN) - 0.01) return col;
    if (p.y > HORIZON + (hiZ - EYE_M) / (zFar * SKY_TAN) + gl.height * 1.3) return col;

    int reach = int(ceil(gl.height * 0.85 / gl.cellW)) + 1;
    float ci = floor(p.x / gl.cellW);
    float zMid = 0.5 * (zNear + zFar);

    for (int k = -reach; k <= reach; k++)
    {
        float cell = ci + float(k);
        float cx0 = (cell + 0.5) * gl.cellW;
        float xs = (cx0 - aspect * 0.5) * SKY_TAN;
        float yN = fieldY(xs * zNear, zNear);
        float yF = fieldY(xs * zFar, zFar);
        if (p.y < min(yN, yF) - 0.004 || p.y > max(yN, yF) + gl.height * 1.3) continue;
        float2 gm = float2(xs * zMid, zMid);
        // The bank in front hides the ground just beyond its brow: the field's
        // screen height in this column at a few distances (a blade is out of sight
        // if nearer ground stands higher on screen than its root).
        float bankY[6];
        bool checkBank = zFar > 7.0 && zNear < 60.0;
        for (int b = 0; b < 6; b++)
        {
            float zb = 6.0 + 2.6 * float(b);
            bankY[b] = checkBank ? fieldY(xs * zb, zb) : -1.0;
        }
        float2 pm = fieldPseudo(gm);
        float wind = windField(pm.x * 0.30 + pm.y * 0.1, t);
        float vis = cloudShadowW(gm, t);
        bool rootLit = false;
        float3 rootC = ground;
        // Tussocks: the grass grows in clumps of taller and shorter blades.
        float clump = fbm(float2(cx0 * 5.0 / max(gl.height * 30.0, 0.05) + gl.seed * 3.1, 0.5), 3);
        float clumpH = 0.35 + 1.0 * smoothstep(0.30, 0.78, clump);
        // Near the track, find which blades stand on the ballast (only weeds do).
        bool nearTrack = false;
        if (zFar > 45.0 && zNear < 400.0)
        {
            float2 dir;
            float3 tr = trackNearest(gm, dir);
            nearTrack = abs(tr.x) + tr.z < 4.0 + (zFar - zNear) * 0.6;
        }

        for (int j = 0; j < BLADES_PER_CELL; j++)
        {
            float hs = cell * 7.13 + float(j) * 3.71 + gl.seed * 17.9;
            float r1 = hash11(hs);
            float r2 = hash11(hs + 1.17);
            float r3 = hash11(hs + 2.31);
            float r4 = hash11(hs + 3.53);
            float r6 = hash11(hs + 5.97);

            float rx = (cell + r1) * gl.cellW;
            float zr = EYE_M / (lerp(gl.d1, gl.d0, r2) * SKY_TAN);
            if (zr < zRange.x || zr >= zRange.y) continue;
            // Sparser close up, so the nearest tufts do not wall off the view.
            if (hash11(hs + 4.4) < 0.45 * (1.0 - smoothstep(8.0, 16.0, zr))) continue;
            float xr = (rx - aspect * 0.5) * SKY_TAN * zr;
            float ry = fieldY(xr, zr);
            if (checkBank)
            {
                float occ = -1.0;
                for (int b = 0; b < 6; b++)
                    if (6.0 + 2.6 * float(b) < zr - 0.8) occ = max(occ, bankY[b]);
                if (ry < occ - 0.0015) continue;
            }
            float bh = grassM(zr) / (zr * SKY_TAN) * clumpH * (0.45 + 0.55 * r3 * r3 + 0.25 * r6);
            if (p.y < ry || p.y > ry + bh) continue;
            // Nothing grows on the ballast, and the grass beside it is kept short
            // (the line is cleared), so it never stands over the rails.
            if (nearTrack)
            {
                float2 dd;
                float3 trk = trackNearest(float2(xr, zr), dd);
                float e = abs(trk.x) + trk.z * 1.5;
                if (e < 2.4 + (vnoise(float2(xr, zr) * 0.9) - 0.5) * 0.5) continue;
                bh *= lerp(0.30, 1.0, smoothstep(2.4, 7.0, e));
            }
            if (p.y > ry + bh) continue;

            // Leaf: x bends with s^2 (supple tip); long leaves arc over and droop.
            float flutter = sin(t * (1.4 + r6) + r4 * 6.2831) * 0.05 + sin(t * 3.3 + r1 * 20.0) * 0.015;
            float lean = (r4 - 0.42) * 1.30;
            float bendAmt = lean + wind * 0.36 + flutter;
            float droop = saturate(abs(bendAmt) * 0.55) * 0.31;

            // Solve y(s) = ry + bh * (s - droop * s^3) for s (Newton; monotonic for droop < 1/3).
            float target = (p.y - ry) / bh;
            float s = target;
            for (int it = 0; it < 3; it++)
            {
                float f = s - droop * s * s * s - target;
                s -= f / (1.0 - 3.0 * droop * s * s);
            }
            s = saturate(s);

            float bend = bendAmt * bh;
            float cx = rx + bend * s * s;
            float dxds = 2.0 * bend * s;
            float dyds = bh * (1.0 - 3.0 * droop * s * s);
            float slope = dxds / max(dyds, 1e-4);
            float dx = (p.x - cx) / sqrt(1.0 + slope * slope);

            float shape = sqrt(saturate(s * 6.0 + 0.15)) * pow(1.0 - s, 0.9);
            float w = gl.width * (0.6 + 0.8 * r6) * shape + px * 0.12;
            // Blades thin out with distance (fewer, not ghostlier), so the far grass
            // dissolves into the meadow texture.
            float keep = 1.0 - smoothstep(0.2, 1.0, 1.0 - r2) * gl.depth * 0.6;
            if (hash11(hs + 8.41) > keep) continue;
            float cov = saturate((w - abs(dx)) / px + 0.5);
            if (cov <= 0.0) continue;

            // Flat painted tones: deep at the root, the meadow colour mid-blade,
            // lighter and warmer at the tip; each blade a little lighter or darker.
            float near = 1.0 - smoothstep(9.0, 22.0, zr);
            // Painted with the meadow colour where it grows (evaluated once per
            // tussock, near by; far off the background is the same ground).
            if (zMid < 120.0 && !rootLit) { rootC = groundAtRoot(gm, t); rootLit = true; }
            float tone = lerp(lerp(0.42, 0.72, near), 1.0, smoothstep(0.0, 0.45, s)) * lerp(1.0, 1.32, smoothstep(0.45, 1.0, s));
            float3 c = (zMid < 120.0 ? rootC : ground) * tone * lerp(0.82, 1.18, r3);
            // Close up, a blade shows its midrib and a lighter sunward half.
            float acrossB = dx / max(w, 1e-5);
            c *= 1.0 + near * (0.10 * smoothstep(-0.2, 0.8, acrossB) - 0.06 * exp(-acrossB * acrossB * 30.0));
            c = lerp(c, c * float3(1.18, 1.10, 0.70), saturate(r6 * 1.6 - 0.9));   // a few straw-tinted blades
            // Sunlit tips catch a warm light.
            float tipLight = smoothstep(0.55, 0.95, s) * vis * step(0.35, r1);
            c += SUN * float3(0.060, 0.064, 0.024) * tipLight;
            // Gust sheen: where the breeze presses the grass over, the bent upper blades
            // flash pale, so the wind shows as waves rolling across the field.
            float gust = smoothstep(0.55, 0.95, wind) * smoothstep(0.35, 0.9, s);
            c = lerp(c, c * float3(1.30, 1.26, 1.05) + float3(0.016, 0.022, 0.008), gust * vis * 0.75);
            if (zMid >= 120.0) c = applyHaze(c, haze);
            col = lerp(col, c, cov);
        }
    }
    return col;
}

// Draws the blades rooted between zRange.x and zRange.y metres, so the grass
// behind an object can go under it and the grass in front over it.
float3 drawGrass(float3 col, float2 p, float2 zRange, float3 ground, float haze, float aspect, float t, float px)
{
    if (p.y > HORIZON + 0.06) return col;
    // Rows from the skyline down to the bank in front; distances to the horizon
    // shrink geometrically, and the blades with them.
    for (int i = GRASS_LAYERS - 1; i >= 0; i--)
    {
        GrassLayer gl;
        gl.d0     = 1.53 * pow(0.78, float(i));
        gl.d1     = gl.d0 * 0.78;
        float zNear = EYE_M / (gl.d0 * SKY_TAN);
        gl.height = grassM(zNear) / (zNear * SKY_TAN);
        gl.cellW  = gl.height * 0.05;
        gl.width  = gl.height * lerp(0.016, 0.0085, smoothstep(9.0, 24.0, zNear));
        gl.depth  = float(i) / float(GRASS_LAYERS - 1);
        gl.seed   = float(i) + 1.0;
        col = drawGrassLayer(col, p, gl, ground, haze, zRange, aspect, t, px);
    }
    return col;
}

// ---------------------------------------------------------------------------
// Post: tonemap and grade
// ---------------------------------------------------------------------------

float3 acesFilm(float3 x)
{
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

// The painting's grade (display-referred, after the tonemap): a warm summer
// light - shade kept clean and only faintly cool, the light parts golden; a
// gentle S-curve gives the picture its punch without crushing the shade or
// clipping the light.
float3 paintGrade(float3 c)
{
    float l = luminance(c);
    float sh = sq(1.0 - saturate(l * 1.6));
    c = c * lerp(float3(1.0, 1.0, 1.0), float3(1.0, 1.0, 1.03), sh);
    c *= lerp(float3(1.0, 1.0, 1.0), float3(1.035, 1.015, 0.955), smoothstep(0.35, 0.95, l));
    l = luminance(c);
    c = lerp(float3(l, l, l), c, 1.06);
    // S-curve about mid grey in perceptual space.
    float3 e = sqrt(saturate(c));
    e = e + 0.22 * (e - 0.5) * (1.0 - abs(2.0 * e - 1.0));
    return saturate(e * e);
}

float3 linearToSrgb(float3 c)
{
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055;
    return float3(c.x <= 0.0031308 ? lo.x : hi.x,
                  c.y <= 0.0031308 ? lo.y : hi.y,
                  c.z <= 0.0031308 ? lo.z : hi.z);
}

float3 renderScene(float2 fragCoord, float2 res, float t)
{
    float aspect = res.x / res.y;
    float px = 1.0 / res.y;
    float2 p = float2(fragCoord.x, res.y - fragCoord.y) * px;  // y up, height = 1

    float3 col = skyColor(p, aspect, t);
    col = drawClouds(col, p, aspect, t, px);
    // Humid haze lying along the horizon: the far towers rise out of it.
    float hb = p.y - HORIZON;
    float band = exp(-max(hb, 0.0) / 0.035) * (0.80 + 0.20 * fbm(float2(p.x * 3.0 - t * 0.003, 1.7), 3));
    col = lerp(col, HAZE * 1.12, saturate(band) * 0.78);
    float3 w = fieldHit(p, aspect);
    float gHaze;
    float3 gLight;
    float3 gw = w.z > 0.0 ? w : float3((p.x - aspect * 0.5) * SKY_TAN * 900.0, 10.0, 900.0);
    float3 ground = groundShade(gw, t, gHaze, gLight);
    col = drawGround(col, p, w, aspect, t, px, ground, gHaze, gLight);
    // Low mist drifting slowly over the far field and the skyline.
    float mistY = abs(p.y - HORIZON + 0.004);
    float mist = exp(-mistY / 0.018) * smoothstep(0.42, 0.78, fbm(float2(p.x * 2.4 - t * 0.010, p.y * 14.0 + t * 0.002), 4));
    col = lerp(col, HAZE * 1.10, mist * 0.35);


    // The yard's structures and a bush may cover this pixel; the grass is drawn
    // in depth slices around them, far to near, so blades rooted behind an
    // object go under it and those in front over it.
    float yardZ;
    float4 yard = drawYard(p, aspect, t, px, yardZ);
    float wireZ = yard.a > 0.5 ? yardZ : -1.0;
    float2 bushBase;
    float bushH;
    int bi = bushAt(p, aspect, bushBase, bushH);
    float bushZ = bi >= 0 ? BUSHES[bi].z : -1.0;
    // The lone tree stands beside the line, where a footbridge once stood (drawn
    // in depth order with the grass, so its trunk stands in it, not over it).
    float3 treeW = onGround(TREE_POS);
    float2 treeB = projectWorld(treeW, aspect);
    float treeH = TREE_M / (treeW.z * SKY_TAN) / 0.85;
    float2 tq = (p - treeB) / treeH;
    float treeZ = (tq.y > -0.08 && tq.y < 1.3 && abs(tq.x) < 0.95) ? treeW.z : -1.0;
    float zFar = 1e5;
    if (yard.a <= 0.0) yardZ = -1.0;
    for (int k = 0; k < 3; k++)
    {
        // The farthest remaining occluder first: 0 yard, 1 bush, 2 the tree.
        int which = -1;
        float z = -1.0;
        if (yardZ > z) { z = yardZ; which = 0; }
        if (bushZ > z) { z = bushZ; which = 1; }
        if (treeZ > z) { z = treeZ; which = 2; }
        if (which < 0) break;
        col = drawGrass(col, p, float2(z, zFar), ground, gHaze, aspect, t, px);
        zFar = z;
        if (which == 0)
        {
            col = col * (1.0 - yard.a) + yard.rgb;
            yardZ = -1.0;
        }
        else if (which == 1)
        {
            col = drawTree(col, p, bushBase, bushH, 81.0 + float(bi) * 3.0, 0.55 * (1.0 - exp(-BUSHES[bi].z / 900.0)), t, px, true);
            bushZ = -1.0;
        }
        else
        {
            col = drawTree(col, p, treeB - float2(0.0, 0.002), treeH, 77.0, 0.55 * (1.0 - exp(-treeW.z / 900.0)), t, px, false);
            treeZ = -1.0;
        }
    }
    col = drawGrass(col, p, float2(0.0, zFar), ground, gHaze, aspect, t, px);
    col = drawWires(col, p, aspect, px, wireZ);

    // A soft graduated darkening along the bottom edge (as in the composited
    // paintings): the foreground settles into a deeper green and the eye goes
    // to the bright middle distance.
    col *= 0.95 * lerp(0.74, 1.0, smoothstep(0.0, 0.17, p.y));
    return col;   // scene-linear light at the film plane, before the lens's own effects
}

// ---------------------------------------------------------------------------
// Camera: lens and film
//
// The picture is taken as on 35 mm motion-picture film. The gate is Super 35
// with a 16:9 extraction (24.9 x 14.0 mm); the lens a vintage spherical cine
// prime of 26 mm, wide open at T2.8 - so the vertical field of view is
// 2 atan(7 / 26) = 30.2 degrees (SKY_TAN above follows FOCAL_MM). In order, as
// the light goes:
//   * lens: a slight barrel distortion; lateral chromatic aberration (red
//     imaged a little larger than green, blue a little smaller, so contrasty
//     edges toward the corners fringe red / cyan, ~1.5 px at the corners in a
//     1080-line frame); natural cos^4 fall-off with some mechanical
//     vignetting; veiling glare from the uncoated-era glass - a soft wide glow
//     that lifts the shadows a touch round bright areas
//   * film: halation - light that passes the emulsion reflects off the base
//     and re-exposes the red-sensitive layer round the highlights, a warm red-
//     orange glow; the stock's response (ACES curve and the painting's warm
//     grade), slightly lifted warm blacks and a slightly gentler saturation of
//     a vintage print; colour grain, strongest in the mid-tones; from frame to
//     frame the film weaves a fraction of a pixel in the gate and the exposure
//     flickers faintly.
// Distances are in frame heights unless named, so the look holds at any size.
// ---------------------------------------------------------------------------

static const float GATE_H_MM     = 14.0;     // Super 35, 16:9 extraction (24.9 x 14.0 mm)
static const float FOCAL_MM      = 26.0;     // focal length
static const float LENS_BARREL   = 0.020;    // barrel distortion (k1 over the half diagonal)
static const float LENS_CA       = 0.0016;   // lateral colour: red / blue magnification offset
static const float LENS_VIGNETTE = 0.60;     // share of cos^4 fall-off left uncorrected
static const float LENS_GLARE    = 0.040;    // veiling glare: share of light spread wide
static const float FILM_HALATION = 0.22;     // strength of the red halo round highlights
static const float FILM_FADE     = 0.022;    // lift of the blacks
static const float FILM_GRAIN    = 0.032;    // grain amplitude in the mid-tones
static const float FILM_FPS      = 24.0;

// Lens fall-off at centred frame position q (frame heights): cos^4 of the field
// angle, partly - the rest is mechanical vignetting at full aperture.
float lensVignette(float2 q)
{
    float tanT = length(q) * GATE_H_MM / FOCAL_MM;
    float c2 = 1.0 / (1.0 + tanT * tanT);
    return lerp(1.0, c2 * c2, LENS_VIGNETTE);
}

// Develop and print: the stock's tone curve and the grade, a vintage print's
// colour, grain, then sRGB. c is linear light on the film; p in frame heights.
float3 filmDevelop(float3 c, float2 p, float t, float2 fragCoord)
{
    float frame = floor(t * FILM_FPS);
    c *= 1.0 + (hash11(frame * 1.37 + 0.5) - 0.5) * 0.020;     // exposure flicker
    c = acesFilm(c);
    c = paintGrade(c);
    // Vintage print: a touch less saturated, warm in the light, the blacks lifted
    // to a warm grey.
    float l = luminance(c);
    c = lerp(float3(l, l, l), c, 0.93) * float3(1.015, 1.0, 0.965);
    c = c * (1.0 - FILM_FADE) + FILM_FADE * float3(1.0, 0.92, 0.80);
    // Colour grain: dye clouds a pixel or so across (in a 1080-line frame),
    // mostly shared by the three layers, strongest in the mid-tones, new each frame.
    float2 gp = p * 1080.0 / 1.3 + hash11(frame * 0.71) * 1000.0;
    float gL = vnoise(gp) + vnoise(gp * 1.9 + 31.7) - 1.0;
    float3 gC = float3(vnoise(gp * 1.3 + 7.1), vnoise(gp * 1.3 + 13.9), vnoise(gp * 1.3 + 21.3)) - 0.5;
    float amp = FILM_GRAIN * (0.35 + 2.6 * l * (1.0 - l));
    c = saturate(c + (gL * 0.8 + gC * 0.5) * amp);
    float3 srgb = linearToSrgb(c);
    srgb += (hash12(fragCoord + frac(t) * 37.0) - 0.5) / 255.0;  // dither the sky gradient
    return srgb;
}

// The pass-1 scene at uv through mip level lod.
float4 sceneAt(float2 uv, float lod) { return gInput.SampleLevel(gSampler, uv, lod); }

// Lens and film over the pass-1 scene, for output pixel fragCoord.
float3 lensAndFilm(float2 fragCoord, float2 res, float t)
{
    float aspect = res.x / res.y;
    float2 p = float2(fragCoord.x, res.y - fragCoord.y) / res.y;
    float2 q = (fragCoord / res - 0.5) * float2(aspect, 1.0);    // centred, frame heights, y down
    // Gate weave: the film settles a fraction of a pixel differently each frame.
    float frame = floor(t * FILM_FPS);
    q += (float2(hash11(frame * 3.17), hash11(frame * 5.91)) - 0.5) * 0.0005;
    // Barrel distortion, scaled so the corners stay at the corners.
    float hd2 = 0.25 * (aspect * aspect + 1.0);
    float k = (1.0 + LENS_BARREL * dot(q, q) / hd2) / (1.0 + LENS_BARREL);
    float2 qs = q * k;
    float2 toUv = float2(1.0 / aspect, 1.0);
    // Lateral colour: each primary imaged at its own magnification.
    float3 c;
    c.r = sceneAt(qs * (1.0 + LENS_CA) * toUv + 0.5, 0.0).r;
    float4 g = sceneAt(qs * toUv + 0.5, 0.0);
    c.g = g.g;
    c.b = sceneAt(qs * (1.0 - LENS_CA) * toUv + 0.5, 0.0).b;
    float2 uv = qs * toUv + 0.5;
    // Veiling glare: the scene spread wide (mips several sizes up) laid over.
    float lod0 = log2(res.y * 0.006);
    float3 glow = sceneAt(uv, lod0 + 1.0).rgb * 0.30 + sceneAt(uv, lod0 + 2.0).rgb * 0.30
                + sceneAt(uv, lod0 + 3.0).rgb * 0.25 + sceneAt(uv, lod0 + 4.0).rgb * 0.15;
    c = lerp(c, glow, LENS_GLARE);
    c *= lensVignette(qs);
    // Halation: the highlights (alpha), spread a little, re-expose the red layer.
    float hal = sceneAt(uv, lod0).a * 0.55 + sceneAt(uv, lod0 + 1.0).a * 0.45;
    c += float3(1.0, 0.38, 0.16) * hal * FILM_HALATION;
    return filmDevelop(c, p, t, fragCoord);
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

[shader("compute")]
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID)
{
    uint2 size = uint2(gScene.resolution);
    if (any(id.xy >= size)) return;
    float3 c = renderScene(float2(id.xy) + 0.5, gScene.resolution, gScene.time);
    // Alpha: how far the light is past the film's shoulder, for the halation.
    gOutput[id.xy] = float4(c, max(luminance(c) - 0.9, 0.0));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void postMain(uint3 id : SV_DispatchThreadID)
{
    uint2 size = uint2(gScene.resolution);
    if (any(id.xy >= size)) return;
    gOutput[id.xy] = float4(lensAndFilm(float2(id.xy) + 0.5, gScene.resolution, gScene.time), 1.0);
}

struct VSOut
{
    float4 position : SV_Position;
};

[shader("vertex")]
VSOut vertexMain(uint vid : SV_VertexID)
{
    float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
    VSOut o;
    o.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

[shader("fragment")]
float4 fragmentMain(VSOut input) : SV_Target
{
    float2 res = gScene.resolution;
    float2 fc = input.position.xy;
    float3 c = renderScene(fc, res, gScene.time);
    c *= lensVignette((fc / res - 0.5) * float2(res.x / res.y, 1.0));
    return float4(filmDevelop(c, float2(fc.x, res.y - fc.y) / res.y, gScene.time, fc), 1.0);
}
