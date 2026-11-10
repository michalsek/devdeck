# Adding sound packs

For agents asked to add a voice pack to DevDeck. There's no installer; copy the folder.

A pack is a folder in `~/Library/Application Support/DevDeck/Sounds/Packs/` holding an
`openpeon.json` manifest (CESP, the format peon-ping uses; a legacy `manifest.json` works
too) and its sound files. DevDeck picks it up as soon as it appears; choose it on the
Voice Packs page or from the menu.

```
Packs/<pack-id>/
  openpeon.json
  sounds/*.wav|mp3|m4a
```

```json
{
  "cesp_version": "1.0",
  "name": "<pack-id>",
  "display_name": "Shown in DevDeck",
  "categories": {
    "task.complete": { "sounds": [{ "file": "sounds/done.wav", "label": "Done" }] }
  }
}
```

- Categories: `session.start`, `task.acknowledge`, `task.complete`, `task.error`,
  `input.required`, `resource.limit`, `user.spam`. A category without sounds is silent.
- `file` is relative to the pack folder; a bare file name means `sounds/<name>`.
- Published packs are listed in the OpenPeon registry,
  `https://peonping.github.io/registry/index.json` (`packs[]` with `name`,
  `display_name`, `source_repo`, `source_ref`, `source_path`). To install one, fetch
  `github.com/<source_repo>` at `<source_ref>` and copy its `<source_path>` folder to
  `Packs/<name>`:

  ```bash
  git clone --depth 1 --branch "$ref" "https://github.com/$repo" /tmp/pack
  cp -R "/tmp/pack/$path" ~/Library/Application\ Support/DevDeck/Sounds/Packs/"$name"
  ```

  Check the pack's license before sharing it further.
- Removing a pack is deleting its folder.
