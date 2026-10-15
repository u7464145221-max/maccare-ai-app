# MacCare AI – prywatność

Stan na 15.10.2026. Ten opis wynika z kodu programu i jest sprawdzany testami (nazwy testów w nawiasach).

## W skrócie
- MacCare AI nie wysyła żadnych danych poza Twojego Maca. Nie ma kont, telemetrii, analityki ani zdalnych raportów awarii.
- Połączenia sieciowe są dwa i oba zależą od Ciebie:
  - lokalny serwer modelu językowego Ollama pod adresem `127.0.0.1` (tylko gdy masz go zainstalowanego; adres inny niż lokalny jest blokowany – `LoopbackSessionTests`);
  - sprawdzanie aktualizacji na GitHubie – tylko gdy klikniesz „Sprawdź aktualizacje” albo włączysz „raz w tygodniu” (domyślnie wyłączone). To jedno zapytanie o najnowsze wydanie; program nie wysyła danych o Macu, a nowej wersji nie pobiera ani nie instaluje sam (`UpdateCheckerTests`). GitHub widzi przy tym, jak przy każdym zapytaniu, adres IP.
- Program po uruchomieniu niczego nie zmienia. Zmiany są możliwe tylko w trybie Edycja, który włączasz sam i który wyłącza się po 15 minutach bezczynności. Obecnie Edycja pozwala wyłącznie przenieść do Kosza elementy, które sam zaznaczysz (w „Moje pliki” i w Porządkach), oraz odinstalować wybraną aplikację razem z wybranymi jej danymi – zawsze po Twoim potwierdzeniu.

## Co program czyta
- **Nazwy, rozmiary i daty plików** – do mapy dysku, dużych plików i Porządków. Treści plików nie czyta, z wyjątkiem:
  - **Duplikatów** – porównuje zawartość plików o tym samym rozmiarze (skrót kryptograficzny), żeby nie pomylić różnych plików.
  - **Podobnych zdjęć** – odczytuje miniatury zdjęć.
- **Informacje o systemie** – obciążenie procesora i pamięci, stan baterii, temperatura, ustawienia zabezpieczeń (SIP, Gatekeeper, FileVault, zapora), elementy autostartu, otwarte porty, raporty awarii z `~/Library/Logs/DiagnosticReports`. Odczyt odbywa się przez interfejsy systemu i stałą listę poleceń systemowych uruchamianych tylko z określonymi argumentami tylko do odczytu (`CommandExactArgumentsTests`).
- **Pliki w chmurze** (iCloud, Dropbox i podobne): program nigdy nie wywołuje ich pobierania. Plik nieobecny na dysku jest pomijany i oznaczany jako nieodczytany (`PathPolicyHardeningTests`).

## Co program zapisuje (tylko na Twoim Macu)
Wszystko w folderze `~/Library/Application Support/MacCare AI`:
- `history.sqlite` – historia skanów, wykryte problemy, próbki pomiarów (po 7 dniach zagęszczane), dziennik operacji i ustawienia. Ścieżki w katalogu domowym są zapisywane z „~” zamiast nazwy konta.
- `diskmap-cache.lzfse` – zapamiętane rozmiary folderów, żeby mapa dysku pojawiała się od razu po uruchomieniu (ścieżki z „~”).
- `quarantine` – elementy przeniesione do kwarantanny (ta droga jest dziś wyłączona – Porządki przenoszą do Kosza). Można je przywrócić. Po 7 dniach mogą zostać trwale usunięte, ale tylko w trybie Edycja – w trybie tylko do odczytu program ich nie usuwa (`expiredQuarantineIsNotPurgedOnStartupInReadOnly`).

Ustawienia wyglądu (np. widok mapy, ikona w pasku menu) są zapisywane w standardowych preferencjach aplikacji. Tryb Edycja nigdy nie jest zapisywany – po każdym uruchomieniu program działa tylko do odczytu (`ExecutionGuardTests`).

## Asystent AI
Asystent działa wyłącznie lokalnie: przez Ollamę na Twoim Macu albo przez model Apple działający na urządzeniu. Pomiary, o które pytasz, trafiają tylko do tego lokalnego modelu. Asystent ma dostęp wyłącznie do narzędzi odczytu i niczego nie zmienia; proponowane operacje widzisz jako podgląd.

## Eksport raportu
Raport tworzy się tylko na Twoje żądanie i zapisuje tam, gdzie wskażesz. Do wyboru są trzy zakresy: minimalny (bez ścieżek i nazw), standardowy (nazwa użytkownika, komputera i adresy e-mail zastąpione znacznikami) i pełny (tylko do własnego użytku).

## Uprawnienia
- **Pełny dostęp do dysku** – opcjonalny. Bez niego część folderów (np. Poczta, Safari) jest pomijana, a wynik oznaczony jako niepełny.
- **Hasło administratora** – tylko w systemowym oknie macOS, gdy sam poprosisz o szczegółowe czujniki (jednorazowy odczyt `powermetrics`). Hasło nie trafia do programu i nie jest zapisywane.

## Jak usunąć dane programu
Zamknij MacCare AI i przenieś do Kosza folder `~/Library/Application Support/MacCare AI`. Preferencje wyglądu usuwa się razem z aplikacją.
