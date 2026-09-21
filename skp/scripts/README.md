# SketchUp application scripts

These adapters call MoosasPy's reusable model/solver APIs. Ruby owns SketchUp
geometry, session checks, process scheduling and delivery to the Web dialog.
No SketchUp task orchestration is imported by MoosasPy.

Conversion debugging: recognition/Remodel and IDF conversion currently launch a
visible Windows console using python.exe, stream progress there and retain
stdout.log. Closing the console cancels the worker and reports failure; normal
completion closes it automatically. Completion callbacks remain asynchronous.
Model-page Visualization On/Off call the existing MoosasRender face-type
visualization methods used by the toolbar, with no separate palette or UI API.

Run from the plugin root using the bundled Python:

| Workflow | Replay command |
| --- | --- |
| Main energy/daylight | `python/python.exe -m skp.scripts.main_analysis request.json` |
| Main with stdout capture | `python/python.exe skp/scripts/replay_main_analysis.py request.json` |
| Recognition/Remodel | `python/python.exe -m skp.scripts.transform_job request.json` |
| SVG | `python/python.exe -m skp.scripts.render_space_svg request.json` |
| Original static SVG CLI | `python/python.exe skp/scripts/render_space_svg.py model.ttl output.svg` |
| Airflow | `python/python.exe -m skp.scripts.airflow_job --request request.json` |
| Surface sun/radiation | `python/python.exe -m skp.scripts.surface_analysis_job request.json` |
| EPW import preparation | `python/python.exe -m skp.scripts.import_station job-directory` |
| IDF export | `python/python.exe -m skp.scripts.idf_export request.json` |
| Parameter preparation only | `python/python.exe -m skp.scripts.space_settings request.json` |

Transform requests contain `input_file`, `rdf_file`, `geo_file` arrays and optional
`settings_path`. IDF requests contain `rdf_paths`, `output_dir`, optional
`template_path`. Main and airflow retain their previous request schema. EPW
preparation uses `request.json` and `source.epw` in the job directory. SVG requests
contain `context`, exact `rdf_paths`, and optional ID-indexed `names`.

## Runtime and compatibility

- `skp/runtime/jobs`: task requests, snapshots, results, logs, SVG and save journals.
- `skp/runtime/models`: editable current recognition RDF, separate from immutable jobs.
- `skp/runtime/settings`: versioned settings JSON, keyed by a hash of model identity.
- Other generated geometry/default exports use `skp/runtime`; user-chosen export
  destinations are preserved. Shared weather/template/material databases stay in MoosasPy.
- Previous job directories are retained unchanged. Old requests can be replayed
  with the new entrypoints; old generated `run.py` files may reference removed imports.
- Historical generated `skp/pyw_script` files were retained in
  `skp/runtime/legacy-scripts`; they are not executable supported entrypoints.
- Legacy title-based settings JSON is imported once when the model's new settings
  document is absent. Existing legacy space values are preserved, not discarded.

## Model page protocol

`update_model_data` still carries the Ruby model summary and space settings.
`model_page_status` adds `context` and `settings_version` alongside busy/selection.
`model_svg` carries the same context, source/level entries, SVG text, space URI/ID
mapping, hit IDs and render warnings; loading/errors use that same channel.
`show_space` remains the display action. `model_clear_selection` clears Model-page
selection without changing SketchUp visibility.

`space_parameter_save` carries one JSON payload:
`request_id, context, settings_version, space_id, field, value`.
`space_parameter_result` acknowledges the normalized value and new `revision`;
`space_parameter_error` retains the request identity and an inline message.
Only Enter commits; blur keeps a per-space draft and Esc discards it.

| UI/Ruby key | Meaning / validation | RDF value |
| --- | --- | --- |
| `zone_name` | Nonempty single-line name | string literal |
| `zone_wallU`, `zone_winU` | U-value, W/(m²·K), > 0 | numeric literal |
| `zone_win_SHGC` | 0–1 | numeric literal |
| `zone_h_temp`, `zone_c_temp` | °C; heating ≤ cooling | numeric literal |
| `zone_collingEER`, `zone_HeatingEER` | Existing API spellings; > 0 | numeric literal |
| `zone_ppsm` | people/m²; ≥ 0 | numeric literal |
| `zone_equipment`, `zone_lighting` | W/m²; ≥ 0 | numeric literal |
| `zone_infiltration` | ACH; ≥ 0 | numeric literal |

Predicates use `https://moosas#<key>` on the identified BOT Space, plus
`moosas:hasSetting "<key>"` and `moosas:explicitSetting "<key>"`.
Readers prefer these URI predicates and accept the old literal-predicate form.
The misspelling `zone_inflitration` is normalized on read.

Main applies the selected template then saved explicit overrides. The generic
space object stores `explicit_settings`; the energy adapter/runner respects
explicit numeric lighting/equipment/occupancy instead of substituting a template
schedule reference. Topology is never re-exported during a field edit.

## Save safety

Python prepares targeted RDF and JSON replacements without publishing. Ruby checks
model/context, geometry signature, settings revision and input file hashes before
committing. File backups and `transaction.json` support rollback and interrupted
commit recovery. Only current editable RDF is targeted, never earlier job snapshots.
Re-recognition loads saved values by stable ID and writes them to the new RDF.
Unmatched saved IDs are reported in the transform log, not applied to other spaces.

## Verification (2026-09-19)

- `python/python.exe -m unittest discover -s tests -p "test_*.py"`
- `node tests/model_page_ui_test.js`; Main/Climate JS contract tests also pass.
- Live Bridge: 48 spaces / 7 elevation groups, one SVG at a time, 12 inputs,
  no former space buttons or face-type panel. DOM layout and SVG sanitization passed.
- Live save, fresh recognition retention, and injected second-file commit failure
  were checked. Failure restored both files and the Ruby settings. Test lighting
  value was restored from 4 to 3 after validation.
- Main fast and ray-radiation jobs passed under the new runtime directory.
- `space-validation-20260919-47408-1qqf1re/checks.json`: saved RDF reloaded directly
  in Python; changing lighting 3→4 changed the target space lighting EUI
  16.36→21.81 kWh/m²/year. IDF export and Chicago EPW preparation passed.
- Live Main analysis without recognition completed successfully after the edit.
- Native airflow regression remains **failed**: a network path has a `None`
  endpoint, reaching `int(p.fromZone)` in `ambient_connectivity_report`.
  `tests/check_airflow_legacy_decoder.py` reproduces it using the pre-migration
  decoding behavior and an untouched old RDF. Solver topology was not changed
  as part of this Model-page task. Airflow request/error contract tests pass.
- Verification used real Bridge routes and DOM inspection, not manual clicks or
  a fresh SketchUp process restart. Face-ID debug display remains off.
