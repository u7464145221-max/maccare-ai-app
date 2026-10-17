# MacCare AI – prywatność

Stan na 16.10.2026, po niezależnym audycie, który znalazł w poprzedniej wersji tego opisu nieprawdziwe zdania. Ten opis wynika z kodu programu i jest sprawdzany testami (nazwy testów w nawiasach).

## W skrócie
- MacCare AI nie wysyła żadnych danych poza Twojego Maca. Nie ma kont, telemetrii, analityki ani zdalnych raportów awarii.
- Program łączy się z siecią w dwóch sytuacjach i obie zależą od Ciebie:
  - **lokalny serwer modelu językowego Ollama** pod adresem `127.0.0.1`. Działa tylko wtedy, gdy masz Ollamę zainstalowaną. Adres inny niż lokalny jest blokowany, a przekierowania nie są śledzone (`LoopbackSessionTests`). Modele, które Ollama uruchamia w chmurze (np. o nazwach kończących się na „-cloud”), są pomijane i odrzucane, bo zapytanie do nich opuszczałoby Maca (`LocalOnlyModelTests`).
  - **sprawdzanie aktualizacji na GitHubie** – tylko gdy klikniesz „Sprawdź aktualizacje” albo włączysz „raz w tygodniu” (domyślnie wyłączone). To jedno zapytanie o najnowsze wydanie. Program nie wysyła przy tym danych o Macu i nie pobiera ani nie instaluje nowej wersji sam (`UpdateCheckerTests`). Jak przy każdym zapytaniu, GitHub widzi Twój adres IP.
- Program nie wysyła zapytań DNS o testowe domeny. Diagnostyka DNS pokazuje tylko lokalną konfigurację (`dnsDiagnosticsShowsLocalConfigurationWithoutQueries`).
- Po uruchomieniu program niczego nie zmienia. Zmiany są możliwe tylko w trybie Edycja, który włączasz sam. Edycja wyłącza się po okresie bezczynności, który wybierasz w Ustawieniach (5–60 min, domyślnie 15). Obecnie Edycja pozwala wyłącznie przenieść do Kosza:
  - elementy, które sam zaznaczysz w „Moje pliki” i w Porządkach,
  - wybraną aplikację razem z wybranymi jej danymi,
  - zaznaczone pozostałości po aplikacjach, których już nie ma.
  Zawsze dzieje się to po Twoim potwierdzeniu, a asystent AI nie może żadnej z tych operacji wykonać (`LLMActionInvariantTests`).

## Co program czyta
- **Nazwy, rozmiary i daty plików** – do mapy dysku, dużych plików i Porządków. Treści plików program nie czyta, z wyjątkiem:
  - **duplikatów** – porównuje zawartość plików o tym samym rozmiarze (skrót kryptograficzny), żeby nie pomylić różnych plików;
  - **podobnych zdjęć** – odczytuje miniatury zdjęć;
  - **aplikacji i elementów autostartu** – odczytuje ich opis (`Info.plist`), pierwsze 512 bajtów pliku programu (architektura procesora) i datę ostatniego użycia ze Spotlight oraz sprawdza podpis kodu przez system.
- **Informacje o systemie** – obciążenie procesora i pamięci, stan baterii, temperatura, ustawienia zabezpieczeń (SIP, Gatekeeper, FileVault, zapora), elementy autostartu, otwarte porty, raporty awarii z `~/Library/Logs/DiagnosticReports`. Odczyt idzie przez interfejsy systemu i stałą listę poleceń systemowych, uruchamianych tylko z określonymi argumentami tylko do odczytu (`CommandExactArgumentsTests`).
- **Kondycja dysku SSD** – dziennik SMART wbudowanego dysku (zużycie, zapas komórek, temperatura, ilość zapisanych danych, godziny pracy, błędy nośnika) przez interfejs systemu IOKit, tylko do odczytu i bez hasła administratora. Numeru seryjnego dysku program nie odczytuje (`SSDHealthTests`, `SSDHealthLiveTests`).
- **Przeglądarki** (zakładka Ochrona → Przeglądarki) – tylko rozmiary plików historii i ciasteczek oraz pamięci podręcznej Safari, Chrome, Brave, Edge, Arc, Vivaldi i Firefoksa. Program nie czyta odwiedzanych adresów ani ciasteczek, niczego nie usuwa i nie zagląda do kontenera Safari (`BrowserPrivacyTests`).
- **Działające programy** – żeby nie wyczyścić pamięci podręcznej programu, który właśnie pracuje, MacCare sprawdza listę procesów Twojego konta. Odczytuje przy tym argumenty wywołania **każdego** z tych procesów, ale zachowuje z nich wyłącznie nazwy rozpoznanych narzędzi deweloperskich (np. npm, cargo, xcodebuild). Zmiennych środowiskowych procesów nie analizuje. Niczego z tego nie zapisuje ani nie wysyła (`ToolActivityTests`).
- **Zainstalowane aplikacje** – foldery Programy oraz systemową bazę aplikacji (LaunchServices), żeby nie uznać za pozostałość danych aplikacji zainstalowanej w innym miejscu.
- **Pliki w chmurze** (iCloud, Dropbox i podobne) – program nigdy nie wywołuje ich pobierania. Plik nieobecny na dysku jest pomijany i oznaczany jako nieodczytany (`PathPolicyHardeningTests`).

## Co program zapisuje (tylko na Twoim Macu)
W folderze `~/Library/Application Support/MacCare AI`:
- `history.sqlite` – historia skanów, wykryte problemy, próbki pomiarów (po 7 dniach zagęszczane; skany, próbki i porównania starsze niż ok. 13 miesięcy, lista wykrytych problemów – niż pół roku, a dziennik operacji – niż 2 lata, są usuwane; łączna suma odzyskanego miejsca zostaje: `retentionPrunesOnlyOldRowsAndKeepsReclaimedTotal`), dziennik operacji, pomiary przed i po operacjach oraz ustawienia. Ścieżki w katalogu domowym są we wszystkich tabelach zapisywane z „~” zamiast nazwy konta (`HistoryRedactionTests`). Jeśli baza się uszkodzi, uszkodzony plik zostaje obok jako `history.sqlite.corrupt-…`.
- `apps-cache.json` – zapamiętane rozmiary aplikacji, żeby ich lista pojawiała się od razu (ścieżki z „~”). Rozmiar jest liczony od nowa, gdy aplikacja się zmieni (`appSizesAreRememberedUntilTheBundleChanges`).
- `diskmap-cache.lzfse` – zapamiętane rozmiary folderów, żeby mapa dysku pojawiała się od razu po uruchomieniu (ścieżki z „~”).
- `bench` – chwilowy folder pomiaru szybkości plików przy operacjach w Edycji. Pliki pomiaru są usuwane od razu po pomiarze.
- `quarantine` – elementy przeniesione do kwarantanny. Ta droga jest dziś wyłączona, bo Porządki przenoszą do Kosza. Trwałe usuwanie z kwarantanny jest dziś niedostępne nawet w trybie Edycja (`expiredQuarantineIsNotPurgedOnStartupInReadOnly`).

W standardowych preferencjach aplikacji (`~/Library/Preferences/io.github.u7464145221-max.maccare.plist`) są zapisywane:
- ustawienia wyglądu (np. widok mapy, ikona w pasku menu);
- włączenie sprawdzania aktualizacji i powiadomień oraz harmonogram automatycznego Smart Scan (z datą włączenia i ostatniego automatycznego skanu);
- czas ostatniego sprawdzenia i ostatnich powiadomień.

Tryb Edycja nigdy nie jest zapisywany – po każdym uruchomieniu program działa tylko do odczytu (`ExecutionGuardTests`).

## Asystent AI
Asystent działa wyłącznie lokalnie: przez Ollamę na Twoim Macu, z modelem uruchomionym na Twoim Macu, albo przez model Apple działający na urządzeniu. Pomiary, o które pytasz, trafiają tylko do tego lokalnego modelu. Asystent wykonuje wyłącznie odczyt i niczego nie zmienia. Operacje (np. przeniesienie do Kosza) może tylko zaproponować – widzisz je jako podgląd i wykonać możesz je wyłącznie sam, w trybie Edycja (`LLMActionInvariantTests`).

## Eksport raportu
W tej wersji aplikacja nie ma eksportu raportu. Gdy powstanie, ten opis zostanie uzupełniony.

## Uprawnienia
- **Powiadomienia** – opcjonalne, domyślnie wyłączone. Po włączeniu w Ustawieniach macOS raz zapyta o zgodę. MacCare pokazuje wtedy lokalne powiadomienia tylko o małej ilości miejsca, krytycznym problemie w Ochronie i nowej wersji (każdy rodzaj najwyżej raz na dobę), raz w tygodniu podsumowanie „co urosło” oraz wynik automatycznego Smart Scan, jeśli go włączysz w Ustawieniach (domyślnie wyłączony; działa tylko, gdy MacCare jest uruchomiony, i niczego nie usuwa). Nic nie jest wysyłane poza Maca (`ImportantNotifierTests`, `WeeklyFeaturesAppTests`).
- **Pełny dostęp do dysku** – opcjonalny. Bez niego część folderów (np. Poczta, Safari) jest pomijana, a wynik oznaczony jako niepełny.
- **Hasło administratora** – podajesz je tylko w systemowym oknie macOS, gdy sam poprosisz o szczegółowe czujniki (jednorazowy odczyt `powermetrics`). Hasło nie trafia do programu i nie jest zapisywane.

## Jak usunąć dane programu
Zamknij MacCare AI i przenieś do Kosza:
- folder `~/Library/Application Support/MacCare AI`,
- plik preferencji `~/Library/Preferences/io.github.u7464145221-max.maccare.plist`.

macOS nie usuwa tego pliku sam, gdy przenosisz aplikację do Kosza.
