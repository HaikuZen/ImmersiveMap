---
paths:
  - "Sources/ImmersiveMap/Tile/Overview/**"
  - "Sources/ImmersiveMap/Style/Default/**"
  - "Tools/Overview/**"
---

# The overview archive

The code shows how the pieces are wired. These are the decisions behind it, which the code cannot show.

- The overview zooms of the globe are painted by data the engine ships, not by the tile service: a small PMTiles archive in the package resources (`Tile/Overview/Resources/overview.pmtiles`, the biomes of RESOLVE Ecoregions 2017 fitted to the Natural Earth coast, the zoom 0 lakes, and the Natural Earth road network at zooms 2 to 5, since the basemap's roads there are the motorways alone) whose tiles the load pipeline appends byte for byte to the map tiles of zooms 0 to 7 (`OverviewTileSource`, `DefaultTileLoadPipeline.download`), since an MVT tile is a protobuf of repeated layers and two tiles concatenated are one tile with both tiles' layers. Nothing below the style knows the layers: the built-in style paints `biome` and `lake` under the basemap's land cover through `BiomeStyles.maximumTileZoom`, and `road` in place of the basemap's roads through `OverviewRoadStyles.maximumTileZoom`, the globe the biomes alone and the country zooms the land cover's forests and fields over them (`BiomeStyles.coverMinimumTileZoom`), so the holes between the raster-derived blobs show the biome, and a style that does not name the layers draws nothing of them. The archive is baked by `Tools/Overview/bake_overview.sh` (mapshaper and tippecanoe over the published RESOLVE and Natural Earth files, outside the SwiftPM build) and is a contract with the style: a new archive bumps `PreparedTileDiskCaching.preparedFormatVersion`, and the setting that lays it in (`TileSettings.OverviewSettings.isEnabled`) is part of the prepared tiles' identity. The biomes' license asks for a credit, and the credit belongs to the data that needs it: the attribution badge is one line of credits (`ImmersiveMapAttribution.Credit`), each shown at the camera zooms its data is on screen at, and the engine lays the overview's credit after the tile source's own while the overview is on, up to `OverviewSettings.creditMaximumZoom`, so the badge names RESOLVE where a biome is drawn and not where none is.
