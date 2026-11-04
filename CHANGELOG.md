# Changelog

## 0.2.0 — 2026-11-04

- Add GPT and MBR partition creation, deletion, metadata editing and guarded resize workflows.
- Add filesystem format, label, check, repair and ownership operations.
- Add filesystem-specific shrink minimum probing for ext, NTFS and mounted Btrfs.
- Add operation locking, dependency-aware safety checks, preparation journaling and correlated UDisks jobs.
- Finalise transactional mount/swap preparation and exact mount restoration reporting across destructive and maintenance operations.
- Add MBR extended-container resizing, readable GPT/MBR partition types and whole-disk logical overwrite mode.
- Integrate format, delete, label, ownership, Check, Repair, mount and swap operations with the common job lifecycle.
- Add AppStream metadata, application icon, About dialog and release packaging metadata.
