# Project Organization Summary

## Documentation Rule

**All documentation files (.md) must be saved to the `docs/` directory.**

This rule is enforced in [CLAUDE.md](CLAUDE.md) to ensure consistent documentation organization.

## Current Structure

```
pugz/
├── README.md                 # Main project README (only .md in root)
├── docs/                     # All documentation goes here
│   ├── INDEX.md             # Documentation index
│   ├── CLAUDE.md            # Development guide
│   ├── api.md               # API reference
│   ├── syntax.md            # Pug syntax guide
│   ├── EXAMPLES.md          # Examples overview
│   ├── DEMO_SERVER.md       # HTTP server guide
│   ├── CLI_TEMPLATES_DEMO.md
│   ├── FEATURES_REFERENCE.md
│   ├── PUGJS_COMPATIBILITY.md
│   ├── COMPILED_TEMPLATES.md
│   ├── COMPILED_TEMPLATES_STATUS.md
│   ├── CLI_TEMPLATES_COMPLETE.md
│   ├── VERIFICATION.md
│   ├── BUILD_SUMMARY.md
│   └── ORGANIZATION.md      # This file
├── src/                      # Source code
├── examples/                 # Example code (NO .md files)
│   ├── demo/                # HTTP server example
│   ├── cli-templates-demo/  # Feature examples
│   └── use_compiled_templates.zig
├── tests/                    # Test files
└── zig-out/                  # Build output
    └── bin/
        └── pug-compile      # CLI tool
```

## Benefits of This Organization

### 1. Centralized Documentation
- All docs in one place: `docs/`
- Easy to find and browse
- Clear separation from code and examples

### 2. Clean Examples Directory
- Examples contain only code
- No README clutter
- Easier to copy/paste example code

### 3. Version Control
- Documentation changes are isolated
- Easy to review doc-only changes
- Clear commit history

### 4. Tool Integration
- Documentation generators can target `docs/`
- Static site generators know where to look
- IDEs can provide better doc navigation

## Documentation Categories

### Getting Started (5 files)
- README.md (root)
- docs/INDEX.md
- docs/CLAUDE.md
- docs/api.md
- docs/syntax.md

### Examples & Tutorials (5 files)
- docs/EXAMPLES.md
- docs/DEMO_SERVER.md
- docs/CLI_TEMPLATES_DEMO.md
- docs/FEATURES_REFERENCE.md
- docs/PUGJS_COMPATIBILITY.md

### Implementation Details (4 files)
- docs/COMPILED_TEMPLATES.md
- docs/COMPILED_TEMPLATES_STATUS.md
- docs/CLI_TEMPLATES_COMPLETE.md
- docs/VERIFICATION.md

### Meta Documentation (2 files)
- docs/BUILD_SUMMARY.md
- docs/ORGANIZATION.md

**Total: 16 documentation files**

## Creating New Documentation

When creating new documentation:

1. **Always save to `docs/`** - Never create .md files in root or examples
2. **Use descriptive names** - `FEATURE_NAME.md` not `doc1.md`
3. **Update INDEX.md** - Add link to new doc in the index
4. **Link related docs** - Cross-reference related documentation
5. **Keep README.md clean** - Only project overview, quick start, and links to docs

## Example Workflow

```bash
# ❌ Wrong - creates doc in root
echo "# New Doc" > NEW_FEATURE.md

# ✅ Correct - creates doc in docs/
echo "# New Doc" > docs/NEW_FEATURE.md

# Update index
echo "- [New Feature](NEW_FEATURE.md)" >> docs/INDEX.md
```

## Maintenance

### Regular Tasks
- Keep INDEX.md updated with new docs
- Remove outdated documentation
- Update cross-references when docs move
- Ensure all docs have clear purpose

### Quality Checks
- All .md files in `docs/` (except README.md in root)
- No .md files in `examples/`
- INDEX.md lists all documentation
- Cross-references are valid

## Verification

Check documentation organization:

```bash
# Should be 1 (only README.md)
ls *.md 2>/dev/null | wc -l

# Should be 16 (all docs)
ls docs/*.md | wc -l

# Should be 0 (no docs in examples)
find examples/ -name "*.md" | wc -l
```

---

**Last Updated:** 2026-01-28  
**Organization Status:** ✅ Complete  
**Total Documentation Files:** 16
