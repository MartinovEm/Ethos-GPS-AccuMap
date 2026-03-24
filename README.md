# GPS AccuMap — Ethos LUA Widget

**GPS AccuMap** is a real-time GPS map widget for FrSky Ethos radios, designed for **line-of-sight (LOS) pilots** who want to see their aircraft's live position on their transmitter screen while flying. It is equally useful for locating a lost or crashed aircraft — the last known position, coordinates, and distance are preserved on screen even after telemetry is lost.

<img width="800" height="480" alt="GPS AccuMap" src="https://github.com/user-attachments/assets/f1f7be41-b9d1-4b82-9fb4-91fd20542197" />


## Sensor Compatibility

GPS AccuMap uses telemetry data from the **FrSky GPS ADV** sensor, as well as any GPS unit compatible with the FrSky ACCESS / ACCST telemetry protocol that provides latitude and longitude fields.

## Why "AccuMap" — What Makes It Accurate

The widget achieves accurate GPS-to-pixel mapping through two key techniques:

1. **Mercator Projection** — GPS coordinates are converted to Mercator Y values using the standard formula:

$$
Y = \ln\left(\tan\left(\frac{\pi}{4} + \frac{\text{lat}}{2}\right)\right)
$$

This compensates for the latitude-dependent distortion inherent in rectangular map images, ensuring the dot is placed at the mathematically correct pixel — not just linearly interpolated.

2. **Automatic Coordinate Loading** — Unlike the built-in Ethos GPS Map widget where you must manually enter corner coordinates, GPS AccuMap reads them automatically from a JSON metadata file generated alongside the map bitmap (see [Map Setup](#map-setup) below). This eliminates manual entry errors entirely.

## Map Setup

Maps are downloaded using the [Ethos GPS Map Generator](https://martinovem.github.io/Ethos-GPS-Map-Generator/), a browser-based tool that lets you select an area and export a bitmap at the correct resolution for your widget.

> Full documentation and source code for the map generator: [github.com/MartinovEm/Ethos-GPS-Map-Generator](https://github.com/MartinovEm/Ethos-GPS-Map-Generator)

**Important:** When you download a map from the generator, it produces **three files**:

| File | Location on SD Card | Purpose |
|---|---|---|
| `ProjectName.png` | `/bitmaps/GPS/` | The map bitmap |
| `ProjectName.json` | `/documents/user/` | Corner coordinates (topLat, bottomLat, leftLon, rightLon) |
| `ProjectName_Zoom_Date_metadata.txt` | `/documents/user/` | Coordinates in DMS, Decimal. **NOT NEEDED** for this Lua |

The JSON file shares the same name as your project title. GPS AccuMap automatically reads the coordinates from this file — **no manual coordinate entry is needed**. This is a key difference from the built-in Ethos GPS Map widget, where you must enter the coordinates from `_medatada` file manually.

## Widget Configuration

<img width="800" height="480" alt="Settings" src="https://github.com/user-attachments/assets/96fe06a4-4a98-4d75-b074-852f5d798cbe" />


| Setting | Description |
|---|---|
| **Map** | Select the bitmap from `/bitmaps/GPS/` |
| **GPS Source** | Select the GPS sensor from the telemetry sensors list. This is the sensor providing latitude/longitude coordinates. |
| **Heading Indicator** | Choose **Dot** (filled orange circle) or **Arrow** (rotatable aircraft icon) |
| **Signal Timeout (s)** | Time in seconds (2–30) before telemetry is considered lost |
| **Distance** | Toggle 3D distance-from-home display |
| **Altitude Source** | Select the altitude sensor (required when Distance is enabled) |
| **Reset Home** | Manually reset the home position |

## Features

### Home Position

The home position is established automatically after the GPS reports a stable position for 100 consecutive telemetry frames (within 0.001° tolerance). A home icon is displayed on the map at that location.

### Heading Indicator

When **Arrow** is selected, the aircraft icon rotates to show the current heading. Since the GPS sensor does not provide heading data directly, the heading is **calculated from consecutive GPS positions** using the forward azimuth (initial bearing) formula:

$$
\theta = \text{atan2}\left(\sin(\Delta\lambda) \cdot \cos(\varphi_2),\;\cos(\varphi_1) \cdot \sin(\varphi_2) - \sin(\varphi_1) \cdot \cos(\varphi_2) \cdot \cos(\Delta\lambda)\right)
$$

where $\varphi$ is latitude and $\lambda$ is longitude in radians. This gives a true geographic bearing that updates as the aircraft moves.

When **Dot** is selected, a simple filled circle is drawn instead.

### 3D Distance from Home

When the Distance toggle is enabled and an Altitude Source is selected, the widget displays the **3D slant distance** from home — not just the ground distance. The formula used:

$$
D_{3D} = \sqrt{D_{ground}^2 + h^2}
$$

where $D_{ground}$ is the haversine great-circle distance and $h$ is the altitude reading. The ground distance itself is calculated using the haversine formula:

$$
D_{ground} = 2R \cdot \arcsin\left(\sqrt{\sin^2\left(\frac{\Delta\varphi}{2}\right) + \cos(\varphi_1)\cos(\varphi_2)\sin^2\left(\frac{\Delta\lambda}{2}\right)}\right)
$$

with $R = 6{,}371{,}000\,\text{m}$ (Earth's mean radius). A 5 m jitter filter suppresses noise when stationary.

### Telemetry Loss Behavior

When telemetry signal is lost (no update within the configured Signal Timeout):

- The indicator (dot or arrow) **turns red** and stays at the **last known position** on the map
- The **last valid GPS coordinates** are displayed in the bottom-right corner
- The **2D ground distance from home** is displayed in the bottom-left corner (always shown on signal loss, regardless of the Distance toggle)

This allows you to read the last coordinates and approximate distance to locate the aircraft.

## Widget Size Compatibility

GPS AccuMap works with **any widget screen size** on Ethos. The map bitmap is **never stretched or compressed** — it is always rendered at its native pixel resolution.

- If the bitmap is **smaller** than the widget area, it is **centered** within the available space
- If the bitmap is **larger** than the widget area, it is **centered and cropped** — only the portion that fits is visible

In both cases, the GPS coordinate mapping remains accurate because the pixel offsets are calculated from the bitmap's actual dimensions and its centering offset, not from the widget screen size. The GPS dot is always placed at the correct pixel regardless of how much of the map is visible.

## File Structure

```
GPSAccuMap/
├── main.lua          -- Widget source code
├── icons/
│   ├── home.png      -- Home position marker (17×20 px)
│   ├── arrow.png     -- White aircraft heading icon
│   └── arrow_red.png -- Red aircraft icon (signal lost)
└── README.md
```

## Requirements

- FrSky Ethos 1.6.x or later
- FrSky GPS ADV sensor (or compatible GPS telemetry source)
- Map bitmap + JSON metadata from [Ethos GPS Map Generator](https://martinovem.github.io/Ethos-GPS-Map-Generator/)
