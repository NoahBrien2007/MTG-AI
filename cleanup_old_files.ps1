# Removes the files made obsolete by the menu / play-mode revamp.
# Run from the project root in PowerShell:   .\cleanup_old_files.ps1
# Afterwards, open the project in Godot once so it rescans scripts and rebuilds .godot/.

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

$files = @(
    # Old AI-vs-AI spectator scene and its scenes
    "scenes\Main.tscn",
    "scenes\Main.tscn73602999147.tmp",
    "scenes\Main.tscn74046765338.tmp",
    "scenes\Main.tscn74210080955.tmp",
    "scenes\Main.tscn74220471249.tmp",
    "scenes\Main.tscn74225398614.tmp",
    "scenes\SpectatorHUD.tscn",
    "scenes\CardTemplate.tscn",          # cards are now built in code (scripts/ui/card_node.gd)

    # Spectator / replay code (replaced by game_controller.gd + board_view.gd)
    "scripts\ai\match_recorder.gd", "scripts\ai\match_recorder.gd.uid",
    "scripts\ui\spectator.gd", "scripts\ui\spectator.gd.uid",                       # -> table_camera.gd
    "scripts\ui\spectator_controller.gd", "scripts\ui\spectator_controller.gd.uid",
    "scripts\ui\spectator_hud.gd", "scripts\ui\spectator_hud.gd.uid",               # -> game_hud.gd
    "scripts\ui\game_visualizer_3d.gd", "scripts\ui\game_visualizer_3d.gd.uid",
    "scripts\ui\card_visual_manager.gd", "scripts\ui\card_visual_manager.gd.uid",   # -> board_view.gd
    "scripts\ui\grid_board_hover.gd", "scripts\ui\grid_board_hover.gd.uid",         # -> board_grid.gd

    # Duplicate / unused
    "scripts\ui\card_3d.gd", "scripts\ui\card_3d.gd.uid",                           # -> card_node.gd
    "scripts\ui\card_template.gd", "scripts\ui\card_template.gd.uid",               # -> card_node.gd
    "scripts\ui\card_texture_loader.gd", "scripts\ui\card_texture_loader.gd.uid",   # merged into scripts/cards/card_texture_loader.gd
    "scripts\ui\freecam.gd", "scripts\ui\freecam.gd.uid",                           # duplicate of the spectator camera
    "scripts\ui\table_viewer.gd", "scripts\ui\table_viewer.gd.uid",                 # empty script
    "scripts\core\game.gd", "scripts\core\game.gd.uid",                             # -> scripts/game/game_session.gd
    "scripts\core\zone.gd", "scripts\core\zone.gd.uid",                             # never used
    "scripts\debug\test_runner.gd", "scripts\debug\test_runner.gd.uid"              # duplicate of tests/test_rules.gd
)

foreach ($f in $files) {
    if (Test-Path $f) {
        Remove-Item $f -Force
        Write-Host "removed  $f"
    }
}

foreach ($d in @("scripts\debug", "scripts\effects")) {
    if ((Test-Path $d) -and -not (Get-ChildItem $d -Force | Select-Object -First 1)) {
        Remove-Item $d -Force
        Write-Host "removed  $d\"
    }
}

Write-Host "Done. Open the project in Godot to let it rescan."

# Godot used to import every CSV under data/raw as a translation table (thousands of
# .translation files). data/raw/.gdignore now stops that; remove the stale imports.
Get-ChildItem "data\raw" -Recurse -Include *.translation,*.import -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force
    Write-Host "removed  $($_.FullName)"
}
