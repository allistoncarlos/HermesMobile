# HermesMobile

Aplicativo iOS nativo (SwiftUI) para conversar com o seu agente **Hermes Agent** (Nous Research) de qualquer lugar, com cara de ChatGPT — inclusive **várias conversas abertas ao mesmo tempo**.

O app **não** depende do `hermes-webui` nem de nenhum serviço intermediário: ele fala **direto com o backend HTTP/WebSocket do seu próprio Hermes** (`hermes serve` / `hermes dashboard`, porta 9119 por padrão) usando o mesmo protocolo JSON-RPC que o app desktop e a aba de chat do dashboard utilizam (`/api/ws` + REST `/api/status`).

---

## Como abrir

1. Instale o **Xcode** (Xcode 15+; deployment target iOS 17.0).
2. Abra `HermesMobile.xcodeproj` no Xcode.
3. Selecione um simulador ou dispositivo e rode o esquema `HermesMobile`.

O arquivo de projeto é gerado a partir de `project.yml` (via [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
xcodegen generate   # regenera o .xcodeproj depois de tocar no project.yml
```

## Estrutura

```
HermesMobile/
├── project.yml
├── HermesMobile.xcodeproj
└── HermesMobile/
    ├── HermesMobileApp.swift
    ├── Config/ServerConfig.swift      # URL, username, token legado (Keychain)
    ├── Networking/
    │   ├── Models.swift
    │   ├── HermesClient.swift         # REST: status, login, ws-ticket
    │   └── HermesWebSocket.swift      # JSON-RPC 2.0 via /api/ws
    ├── ViewModels/HermesViewModel.swift
    ├── Voice/                         # STT + TTS + loop do modo de voz
    └── Views/                         # setup, chat, voice, sidebar
```

---

## Como conectar

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

Se já existir cookie de sessão válido, o app tenta reconectar automaticamente ao abrir.

---

## Chats simultâneos

- Uma única conexão WebSocket.
- Várias conversas abertas (`OpenChat`), cada uma com seu histórico e stream.
- Eventos do servidor são roteados pelo `session_id`.
- Faixa de abas no topo + sidebar com conversas abertas e histórico do servidor.
- Badge vermelho quando outra conversa pede aprovação, esclarecimento ou termina um turno em background.

---

## Modo de voz

Conversa hands-free no estilo do **Hermes Desktop 0.20** (botão de waveform):

1. Grava o microfone no iPhone (VAD).
2. `POST /api/audio/transcribe` — STT nativo do servidor.
3. `prompt.submit` no WebSocket de chat.
4. Enquanto a resposta gera, alimenta `WS /api/audio/speak-stream` (PCM ao vivo, igual ao desktop).
5. Se o provider não tiver streaming, fallback em `POST /api/audio/speak` e toca o áudio.
6. Volta a ouvir. Diga “parar” / “tchau” para encerrar.

Mesmas rotas de áudio do app desktop — usa o TTS/STT configurados em `~/.hermes/config.yaml`.

---

## Protocolo

- **Status:** `GET /api/status` (`auth_required`, `auth_providers`, `auth_flows`).
- **Providers:** `GET /api/auth/providers` (`supports_password`).
- **Login:** `POST /auth/password-login` JSON `{ provider, username, password, next }`.
- **Ticket WS:** `POST /api/auth/ws-ticket` (cookie autenticado) → `{ ticket, ttl_seconds }`.
- **Chat WS JSON-RPC:** `session.create` / `session.resume` / `session.list` / `session.activate`, `prompt.submit`, `image.attach_bytes`, `file.attach`, `pdf.attach`, `approval.respond`, `clarify.respond`, `session.interrupt`.
- **Eventos:** `message.delta`, `message.complete`, `reasoning.delta`, `tool.*`, `approval.request`, `clarify.*`, `turn.*`, etc.

---

## Anexos

No composer, o botão **+** permite anexar fotos (PhotosPicker) ou arquivos (document picker), no estilo ChatGPT:

1. Imagens → `image.attach_bytes` (base64) antes do `prompt.submit`.
2. PDFs → `pdf.attach` (com fallback para `file.attach`).
3. Demais arquivos → `file.attach` com `data_url`.

Limite de 25 MB por anexo (mesmo teto do gateway).

---

## Próximos passos possíveis

- OAuth / OIDC (além de basic password).
- Painel de skills/memória/kanban.
- Notificações push quando um turno termina em background.
