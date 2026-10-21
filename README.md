# ai-conf

Konfiguracja Claude Code trzymana w repo i wdrażana skryptem `ai-sync.sh`.

| Plik | Cel |
|---|---|
| `managed-mcp.json` | serwery MCP -> `/etc/claude-code/managed-mcp.json` |
| `managed-settings.json` | uprawnienia i sandbox -> `/etc/claude-code/managed-settings.json` |
| `.claude/` | hooki i pozostała konfiguracja -> `~/.claude/` |
| `ai-sync.sh` | jednokierunkowa synchronizacja powyższych (`ai-sync.sh --help`) |

## Serwery MCP

### victorialogs

[mcp-victorialogs](https://github.com/VictoriaMetrics/mcp-victorialogs) to binarka w Go, której `ai-sync.sh` nie instaluje.
Przed pierwszym użyciem trzeba ją pobrać ręcznie i wrzucić do `PATH`.

1. Pobierz archiwum dla swojej platformy z [release v1.9.0](https://github.com/VictoriaMetrics/mcp-victorialogs/releases/tag/v1.9.0)
   (np. `mcp-victorialogs_Linux_x86_64.tar.gz`) oraz `checksums.txt` i zweryfikuj sumę kontrolną.
2. Rozpakuj binarkę i umieść ją w katalogu z `PATH`, np.:

   ```bash
   tar -xzf mcp-victorialogs_Linux_x86_64.tar.gz mcp-victorialogs
   install -m 0755 mcp-victorialogs ~/.local/bin/mcp-victorialogs
   command -v mcp-victorialogs
   ```

3. Ustaw zmienne środowiskowe w środowisku, z którego startuje Claude Code (np. w `~/.profile`).
   Wartości nie trafiają do repo, `managed-mcp.json` zawiera tylko referencje `${...}`:

   | Zmienna | Opis |
   |---|---|
   | `VL_INSTANCE_ENTRYPOINT` | URL instancji VictoriaLogs |
   | `VL_INSTANCE_BEARER_TOKEN` | token (blokowany dla poleceń Bash w `managed-settings.json`) |

4. Uruchom `./ai-sync.sh`, zrestartuj Claude Code i sprawdź w `/mcp`, że `victorialogs` jest połączony.

`go install ...@latest` nie działa, bo `go.mod` serwera zawiera dyrektywę `replace`.
Alternatywą jest budowa ze źródeł (`make build`, Go 1.26+).
