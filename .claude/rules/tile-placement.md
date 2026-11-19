---
paths:
  - "Sources/ImmersiveMap/Tile/Placement/**"
  - "Sources/ImmersiveMap/Tile/Drawers/**"
---

# Tile placement

The code shows how the pieces are wired. These are the decisions behind it, which the code cannot show.

- Tiles are shown by one mechanism on both surfaces: the planner decides (`TilePlacementPlanner`, remembering what the last frame showed, so a ground changes only to its own target), the placement prepass marks every placement's ground in the tile-priority stencil with its source's zoom, and every ground pass draws its source at full extent and paints by equality (`TileSourceStencilPriority`). Draw order never decides between sources, and the surfaces differ only in the geometry of the marks and the ground. On the relief the squares also overlap on the screen (a near mountain in front of the ground behind it), so there the prepass first draws the ground's depth, every point of the ground once from the placement the planner gave it (`PlacementGroundSquare`), and marks each square only where its ground is the one in front. On the relief a tile is placed with its terrain or not at all: the planner binds each placement to the terrain tile its slot's ring reads (`PlaceTile.terrain`), places a tile only once that terrain is in, keeps what stood on the ground until then, drawn as it was shown, and every draw of the placement reads that one terrain, so a tile and its heights come and go together and the ground never changes shape under a tile that stays. The heights a frame stops reading wait in a small cache (`GroundReliefSettings.releasedCacheBytes`) for the zoom back. A change to how a tile is chosen or kept goes into the planner, not into a drawer.
