# OpenMoe (app-openmoe)

App de escritorio Windows de ejemplo sobre `llama_cpp_dart`: chat multimodal
(vision) con modelo GGUF descargado **desde HuggingFace**.

## Correr localmente

```powershell
cd app-openmoe
flutter pub get
flutter run -d windows
```

> Windows exige **Developer Mode** habilitado para los symlinks de plugins
> (`start ms-settings:developers`). En CI (GitHub Actions) ya viene activo.

## Flujo de la app

1. **Librería**: en el zip portable las DLLs de llama.cpp ya vienen **junto
   al exe** y la app las detecta solas. Solo si ejecutaras el exe fuera del
   paquete, eliges el `llama.dll` que corresponda con el selector de
   archivos. El paquete registra esa carpeta en el DLL search path de
   Windows y resuelve los `ggml_*` por la cadena llama → ggml-base →
   ggml → ggml-cpu-*.
2. **Modelo**: catálogo con entradas de HuggingFace, con **Qwen 0.8B
   (Qwen3.5-0.8B, ~0.7 GB con mmproj → visión)** como primera y recomendada,
   más las variantes Qwen3.8-Flash-Next (~77–95 GB). Al pedir descarga
   aparece **un diálogo de confirmación** con repo, archivos y tamaño
   aproximado; la descarga a `%USERPROFILE%\OpenMoe\models` admite cancelar
   y reanudar (HTTP Range). También puedes apuntar GGUFs locales
   (modelo + mmproj opcional).
3. **Chat**: adjunta imágenes desde tu PC (file picker) y ver el streaming
   de la respuesta del modelo.
4. **Panel de sistema** (botón monitor en la AppBar): CPU (núcleos, carga),
   RAM (total/libre, RSS del proceso), GPU (nombre + VRAM vía nvidia-smi) y
   el `llama_print_system_info()` de la librería cargada.

## CI

`.github/workflows/build-windows.yml` (raíz del repo):

- `dart analyze` + formato + tests pure-Dart del paquete
- descarga el release `b12050` de llama.cpp y valida cobertura de símbolos +
  probe real del loader (`tool/probe_windows_dlls.dart`)
- `flutter analyze` + `flutter test` + `flutter build windows --release`
- copia las DLLs junto al exe y sube el artefacto `openmoe-windows-portable`
