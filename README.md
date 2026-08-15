# HermesMobile

Native iOS (SwiftUI) client for a self-hosted [Hermes Agent](https://github.com/nousresearch/hermes-agent) (Nous Research). ChatGPT-style UI, several conversations at once, and a **voice-only** Apple Watch companion.

The app talks **directly** to your Hermes HTTP/WebSocket backend (`hermes serve` / `hermes dashboard`, port `9119` by default). It does not use `hermes-webui` or any other proxy.

- [en-US](#en-us)
- [pt-BR](#pt-br)

---

## en-US

### How to open

1. Install **Xcode** (Xcode 15+; deployment target iOS 17.0 / watchOS 10.0).
2. Open `HermesMobile.xcodeproj` in Xcode.
3. In **Signing & Capabilities**, pick **your** Apple Development Team (this repo does not include a team ID).
4. Choose a simulator or device and run the `HermesMobile` scheme (the Watch app is embedded).
5. For Apple Watch: use the `HermesWatch` scheme, or an iPhone with a paired Watch.

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate   # regenerate .xcodeproj after changing project.yml
```

### Layout

```
HermesMobile/
├── project.yml
├── HermesMobile.xcodeproj
├── HermesMobile/                      # iOS app (chat + voice)
│   ├── Companion/CompanionSync.swift  # WatchConnectivity → Apple Watch
│   ├── Config / Networking / Voice / Views
└── HermesWatch/                       # watchOS voice-only app
```

### How to connect

1. Enter your Hermes **server address**. Examples:
   - Local network: `http://192.168.1.50:9119`
   - Tailscale: `http://100.x.x.x:9119` or a MagicDNS hostname
   - HTTPS tunnel: `https://hermes.yourdomain.com`
2. **No auth** (loopback / `--insecure`): address only.
3. **Basic auth (cookie)** — typical for Tailscale / a public bind:
   - Fill in the dashboard **username** and **password** (`dashboard.basic_auth` / `HERMES_DASHBOARD_BASIC_AUTH_*`).
   - The app posts `POST /auth/password-login`, stores session cookies, then asks for a ticket at `POST /api/auth/ws-ticket` before opening the WebSocket.
   - It connects to `ws(s)://…/api/ws?ticket=…` (single-use ticket).
4. **Legacy token** (advanced): only for servers that still use `X-Hermes-Session-Token` / `?token=`.

If a server URL is already saved, the app reconnects on launch. Session cookies (`hermes_session_at` / `hermes_session_rt`) live in the Keychain, so login survives quitting the app — you land in chat while the session is still valid.

### Concurrent chats

- One WebSocket connection.
- Several open conversations (`OpenChat`), each with its own history and stream.
- Server events are routed by `session_id`.
- Tab strip at the top plus a sidebar of open chats and server history.
- Red badge when another conversation needs approval, clarification, or finishes a background turn.

### Voice mode

Hands-free chat in the style of **Hermes Desktop 0.20** (waveform button):

1. Record the iPhone microphone (VAD).
2. `POST /api/audio/transcribe` — server-native STT.
3. `prompt.submit` on the chat WebSocket.
4. While the reply streams, feed `WS /api/audio/speak-stream` (live PCM, same as desktop).
5. If the provider has no streaming, fall back to `POST /api/audio/speak` and play the audio.
6. Listen again. Say “stop” / “bye” (or “parar” / “tchau”) to end.

Same audio routes as the desktop app — it uses the TTS/STT configured in `~/.hermes/config.yaml`.

### Apple Watch

The **Hermes** Watch companion is voice-only (no keyboard, no attachments). The Watch **does not talk to Hermes itself** (Tailscale/LAN from the wrist usually fails): the iPhone is the bridge.

1. Keep Hermes **open and connected on the iPhone**, with the Watch nearby.
2. On the wrist, tap the orb to talk → the iPhone transcribes, asks Hermes, and returns speech.
3. Say “stop” / “bye”, or tap X, to end the turn.
4. Approval prompts show Yes/No on the Watch.

How the relay works:

- Config and connection state go over WatchConnectivity (`applicationContext` / `sendMessage`).
- Recorded audio and TTS audio go as files (`transferFile`).
- The Watch records and plays only. STT, chat, and TTS run on the iPhone.
- The Watch target does not include ViewModels, Config, or the networking stack (except shared models). `WKRunsIndependentlyOfCompanionApp` is `false`.

### Protocol

- **Status:** `GET /api/status` (`auth_required`, `auth_providers`, `auth_flows`).
- **Providers:** `GET /api/auth/providers` (`supports_password`).
- **Login:** `POST /auth/password-login` JSON `{ provider, username, password, next }`.
- **WS ticket:** `POST /api/auth/ws-ticket` (authenticated cookie) → `{ ticket, ttl_seconds }`.
- **Chat WS JSON-RPC:** `session.create` / `session.resume` / `session.list` / `session.activate`, `prompt.submit`, `image.attach_bytes`, `file.attach`, `pdf.attach`, `approval.respond`, `clarify.respond`, `session.interrupt`.
- **Events:** `message.delta`, `message.complete`, `reasoning.delta`, `tool.*`, `approval.request`, `clarify.*`, `turn.*`, and others.

### Attachments

In the composer, **+** attaches photos (PhotosPicker) or files (document picker), ChatGPT-style:

1. Images → `image.attach_bytes` (base64) before `prompt.submit`.
2. PDFs → `pdf.attach` (falls back to `file.attach`).
3. Other files → `file.attach` with `data_url`.

25 MB per attachment (same cap as the gateway).

### Possible next steps

- OAuth / OIDC (beyond basic password).
- Skills / memory / kanban panel.
- Push notifications when a background turn finishes.

---

## pt-BR

Aplicativo iOS nativo (SwiftUI) para conversar com o seu agente **Hermes Agent** (Nous Research) de qualquer lugar, com cara de ChatGPT — inclusive **várias conversas abertas ao mesmo tempo**. No Apple Watch, a conversa é **só por voz**.

O app **não** depende do `hermes-webui` nem de nenhum serviço intermediário: ele fala **direto com o backend HTTP/WebSocket do seu próprio Hermes** (`hermes serve` / `hermes dashboard`, porta 9119 por padrão) usando o mesmo protocolo JSON-RPC que o app desktop e a aba de chat do dashboard utilizam (`/api/ws` + REST `/api/status`).

### Como abrir

1. Instale o **Xcode** (Xcode 15+; deployment target iOS 17.0 / watchOS 10.0).
2. Abra `HermesMobile.xcodeproj` no Xcode.
3. Em **Signing & Capabilities**, escolha o **seu** Apple Development Team (o projeto não inclui team ID).
4. Selecione um simulador ou dispositivo e rode o esquema `HermesMobile` (o app do Watch é embutido).
5. Para o Apple Watch: esquema `HermesWatch`, ou um iPhone com o Watch pareado.

O arquivo de projeto é gerado a partir de `project.yml` (via [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
xcodegen generate   # regenera o .xcodeproj depois de tocar no project.yml
```

### Estrutura

```
HermesMobile/
├── project.yml
├── HermesMobile.xcodeproj
├── HermesMobile/                      # app iOS (chat + voz)
│   ├── Companion/CompanionSync.swift  # WatchConnectivity → iPhone
│   ├── Config / Networking / Voice / Views
└── HermesWatch/                       # app watchOS só de voz
```

### Como conectar

1. Informe o **endereço do servidor** Hermes. Exemplos:
   - Rede local: `http://192.168.1.50:9119`
   - Via Tailscale: `http://100.x.x.x:9119` ou hostname MagicDNS
   - Via túnel HTTPS: `https://hermes.seudominio.com`
2. **Sem autenticação** (loopback / `--insecure`): basta o endereço.
3. **Com basic auth (cookie)** — caso típico em Tailscale / bind público:
   - Preencha **usuário** e **senha** do dashboard (`dashboard.basic_auth` / env `HERMES_DASHBOARD_BASIC_AUTH_*`).
   - O app faz `POST /auth/password-login`, guarda os cookies de sessão e, antes do WebSocket, pede um ticket em `POST /api/auth/ws-ticket`.
   - Conecta em `ws(s)://…/api/ws?ticket=…` (ticket single-use).
4. **Token legado** (opções avançadas): só para servidores que ainda usam `X-Hermes-Session-Token` / `?token=`.

Se já existir configuração salva (URL do servidor), o app tenta reconectar automaticamente ao abrir. Os cookies de sessão (`hermes_session_at` / `hermes_session_rt`) ficam no Keychain, então a autenticação sobrevive ao fechar o app — e entra direto no chat enquanto a sessão ainda for válida.

### Chats simultâneos

- Uma única conexão WebSocket.
- Várias conversas abertas (`OpenChat`), cada uma com seu histórico e stream.
- Eventos do servidor são roteados pelo `session_id`.
- Faixa de abas no topo + sidebar com conversas abertas e histórico do servidor.
- Badge vermelho quando outra conversa pede aprovação, esclarecimento ou termina um turno em background.

### Modo de voz

Conversa hands-free no estilo do **Hermes Desktop 0.20** (botão de waveform):

1. Grava o microfone no iPhone (VAD).
2. `POST /api/audio/transcribe` — STT nativo do servidor.
3. `prompt.submit` no WebSocket de chat.
4. Enquanto a resposta gera, alimenta `WS /api/audio/speak-stream` (PCM ao vivo, igual ao desktop).
5. Se o provider não tiver streaming, fallback em `POST /api/audio/speak` e toca o áudio.
6. Volta a ouvir. Diga “parar” / “tchau” para encerrar.

Mesmas rotas de áudio do app desktop — usa o TTS/STT configurados em `~/.hermes/config.yaml`.

### Apple Watch

O companion **Hermes** no Watch é só conversa por voz (sem teclado nem anexos). O relógio **não fala direto com o servidor** (Tailscale/LAN no pulso costuma falhar): ele usa o iPhone como ponte.

1. Deixe o Hermes **aberto e conectado no iPhone**, com o Watch por perto.
2. No pulso, toque no orb para ouvir → o iPhone transcreve, pergunta ao Hermes e devolve a fala.
3. Diga “parar” / “tchau”, ou toque no X, para encerrar o turno.
4. Pedidos de aprovação aparecem com Sim/Não no pulso.

Como a ponte funciona:

- Configuração e estado de conexão vão pelo WatchConnectivity (`applicationContext` / `sendMessage`).
- Áudio gravado e TTS vão como arquivos (`transferFile`).
- O Watch só grava e toca. STT, chat e TTS rodam no iPhone.
- O target do Watch não inclui ViewModels, Config nem o stack de networking (exceto os models compartilhados). `WKRunsIndependentlyOfCompanionApp` é `false`.

### Protocolo

- **Status:** `GET /api/status` (`auth_required`, `auth_providers`, `auth_flows`).
- **Providers:** `GET /api/auth/providers` (`supports_password`).
- **Login:** `POST /auth/password-login` JSON `{ provider, username, password, next }`.
- **Ticket WS:** `POST /api/auth/ws-ticket` (cookie autenticado) → `{ ticket, ttl_seconds }`.
- **Chat WS JSON-RPC:** `session.create` / `session.resume` / `session.list` / `session.activate`, `prompt.submit`, `image.attach_bytes`, `file.attach`, `pdf.attach`, `approval.respond`, `clarify.respond`, `session.interrupt`.
- **Eventos:** `message.delta`, `message.complete`, `reasoning.delta`, `tool.*`, `approval.request`, `clarify.*`, `turn.*`, etc.

### Anexos

No composer, o botão **+** permite anexar fotos (PhotosPicker) ou arquivos (document picker), no estilo ChatGPT:

1. Imagens → `image.attach_bytes` (base64) antes do `prompt.submit`.
2. PDFs → `pdf.attach` (com fallback para `file.attach`).
3. Demais arquivos → `file.attach` com `data_url`.

Limite de 25 MB por anexo (mesmo teto do gateway).

### Próximos passos possíveis

- OAuth / OIDC (além de basic password).
- Painel de skills/memória/kanban.
- Notificações push quando um turno termina em background.
