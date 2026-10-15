# MacCare AI

Aplikacja do dbania o Maca: pokazuje, co zajmuje miejsce na dysku, co można bezpiecznie posprzątać, jak wyglądają zabezpieczenia i co obciąża komputer. Ma lokalnego asystenta AI, który odpowiada na pytania o Twojego Maca na podstawie pomiarów.

**Zasada nadrzędna: po uruchomieniu program tylko czyta.** Zmiany są możliwe wyłącznie w trybie Edycja, który włączasz sam i który wyłącza się po 15 minutach bezczynności. Nawet wtedy wszystko trafia do Kosza macOS, skąd możesz to przywrócić – nic nie jest kasowane na stałe.

## Co potrafi
- **Smart Scan** – jeden skan: porządki, ochrona i wydajność z oceną stanu i dowodami.
- **Moje pliki** – mapa dysku (bąbelki albo prostokąty), duże pliki, duplikaty, podobne zdjęcia; zmiany od wcześniejszego pomiaru.
- **Porządki** – 47 reguł (pamięć podręczna aplikacji i przeglądarek, logi, narzędzia programistyczne, modele AI, instalatory…); czyszczenie przez Kosz.
- **Ochrona** – SIP, Gatekeeper, FileVault, zapora, autostart z weryfikacją podpisów, otwarte porty, awarie.
- **Wydajność** – procesor, pamięć, bateria, temperatura, najbardziej obciążające procesy.
- **Aplikacje** – lista z rozmiarem i podpisem, możliwe pozostałości, odinstalowanie przez Kosz.
- **Asystent AI** – wyłącznie lokalnie (Ollama na Twoim Macu albo model Apple na urządzeniu), tylko narzędzia odczytu.
- Interfejs po polsku i po angielsku (wg języka systemu).

## Wymagania
Mac z Apple Silicon (M1 lub nowszy), macOS 14 lub nowszy. Wersji dla Intela nie ma.

## Instalacja
1. Pobierz `MacCare-AI-<wersja>.zip` z [Releases](../../releases) i rozpakuj.
2. Przenieś `MacCare AI.app` do folderu Programy.
3. **Pierwsze uruchomienie:** program nie jest jeszcze podpisany certyfikatem Apple Developer ID, więc macOS go zablokuje. Otwórz *Ustawienia systemowe → Prywatność i ochrona* i kliknij **„Otwórz mimo to”** przy MacCare AI.
4. Opcjonalnie: *Pełny dostęp do dysku* (Ustawienia → Prywatność i ochrona) – bez niego część folderów jest pomijana, a wynik oznaczony jako niepełny.

Do czasu podpisu Developer ID każda nowa wersja może ponownie zapytać o dostęp do dysku – macOS traktuje ją jak nową aplikację.

## Aktualizacje
W *Ustawienia → Aktualizacje*: „Sprawdź aktualizacje” albo „Sprawdzaj raz w tygodniu” (domyślnie wyłączone). Program pokazuje nową wersję i otwiera stronę wydania – sam niczego nie pobiera ani nie instaluje.

## Prywatność
Bez kont i telemetrii. Sieć: tylko lokalna Ollama (127.0.0.1) i – po Twoim kliknięciu lub włączeniu – sprawdzanie aktualizacji na GitHubie. Szczegóły: [docs/PRYWATNOSC.md](docs/PRYWATNOSC.md) · [docs/PRIVACY.md](docs/PRIVACY.md).

## Budowanie ze źródeł
Wystarczą Command Line Tools (bez Xcode):
```
./Scripts/build_app.sh        # wynik: build/MacCare AI.app (tylko arm64)
```

---

## English
MacCare AI is a Mac care app: disk map, safe cleanup, security and performance overview, and a local-only AI assistant. **After launch it only reads.** Changes are possible only in Edit mode, which you turn on yourself and which turns off after 15 minutes of inactivity; even then everything goes to the macOS Trash and can be restored. Apple Silicon and macOS 14+ only. The app is not yet signed with an Apple Developer ID: on first launch use *System Settings → Privacy & Security → Open Anyway*. Privacy details: [docs/PRIVACY.md](docs/PRIVACY.md).
