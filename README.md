# iphone-control

Controle o iPhone pelo PC com Windows: a tela do iPhone aparece numa janela do PC (espelhamento AirPlay) e o mouse e o teclado do PC passam a tocar, arrastar e digitar no iPhone.

Como funciona:

- **Imagem:** o [uxplay-windows](https://github.com/leapbtw/uxplay-windows) recebe o "Espelhar Tela" do iPhone pelo Wi-Fi e abre a janela **AirPlay Video Stream**.
- **Controle:** o script `iphone-control.ps1` faz o PC se apresentar ao iPhone como um **teclado + mouse Bluetooth LE** (HID). Clique na janela do espelho vira toque no iPhone; o teclado do PC digita no iPhone.

Não instala nada além do uxplay-windows: o script usa só o PowerShell 5.1 que já vem no Windows.

## Requisitos

- **Windows 10 versão 1803 ou mais nova, ou Windows 11.**
- **Bluetooth LE com suporte ao papel de periférico** (o PC precisa conseguir "anunciar" como acessório). Nem todo adaptador suporta. O `-SelfTest` mostra `Peripheral=True/False` no log.
- **iPhone com AssistiveTouch ligado** (é o que faz o iPhone mostrar e aceitar ponteiro de mouse).
- PC e iPhone **na mesma rede Wi-Fi**, com a rede marcada como **Privada** no Windows.

## Instalação

1. Instale o receptor AirPlay (pede Administrador porque instala o Bonjour junto):

   ```
   winget install leapbtw.uxplay
   ```

2. Abra o uxplay-windows. Quando o Firewall do Windows perguntar, libere **só em rede privada** (não marque rede pública).
3. No ícone do uxplay-windows (perto do relógio), botão direito: **desmarque "Enable Bluetooth Discovery"** e reinicie o app. Esse anúncio usa o mesmo Bluetooth do controle e pode atrapalhar; o Bonjour já faz o iPhone achar o PC.
4. Baixe/clone este repositório numa pasta qualquer.

**Atalho do dia a dia:** dois cliques no `iniciar.bat` abrem o espelho com as opções recomendadas (decodificação por software, que evita a imagem estragada em placas Intel) e já abrem o controle. Repassa argumentos ao `iphone-control.ps1` (ex.: `iniciar.bat -Relative`).

## Primeira vez: parear

1. No iPhone: **Ajustes > Acessibilidade > Toque > AssistiveTouch** = ligado.
2. No PC, rode o script (na pasta do repositório):

   ```
   powershell -ExecutionPolicy Bypass -File .\iphone-control.ps1
   ```

   Ele mostra `=== Pronto. iPhone: Ajustes > Bluetooth > <nome do seu PC> ===`.
3. No iPhone: **Ajustes > Bluetooth**, toque no nome do PC e aceite o pareamento.
4. No console do PC deve aparecer `Inscritos: teclado=1 ponteiro=1 consumer=1` e o prompt muda para `[CONECTADO]`.
5. Espelhe a tela: no iPhone, **Central de Controle > Espelhar Tela > uxplay-windows**. A janela **AirPlay Video Stream** abre no PC.

Para testar sem iPhone (não anuncia nada, não segura teclado/mouse):

```
powershell -ExecutionPolicy Bypass -File .\iphone-control.ps1 -SelfTest
```

## Como usar

Com o script rodando e a tela espelhada:

| No PC | No iPhone |
|---|---|
| Clique na janela do espelho | Toque |
| Clicar e arrastar | Arrastar / deslizar |
| Rodinha do mouse | Rolagem (vira um deslize do dedo) |
| Teclado com a janela do espelho em foco | Digita no iPhone (Ctrl+letra vira Cmd+letra) |
| **Ctrl+V** | Digita o texto copiado no PC (quebra de linha vira espaço) |
| **Ctrl+Shift+V** | Cmd+V (cola o que está copiado no próprio iPhone) |
| **Ctrl+Shift+F12** | Liga/desliga a captura (funciona de qualquer janela) |
| **Ctrl+Shift+F11** | Liga/desliga "sempre no topo" na janela do espelho |
| **Esc** durante um Ctrl+V longo | Cancela a digitação |

Um selo **CONTROLE LIGADO / DESLIGADO** aparece na barra de título do espelho.

O primeiro clique numa janela sem foco só dá foco a ela (e também conta como toque).

No console do script dá para digitar comandos (`help` lista todos): texto solto digita no iPhone, `tap 0.5 0.5`, `swipe ...`, `home`, `status`, `q` para sair.

Opções úteis:

- `-PasteNewlines` — no Ctrl+V, quebra de linha vira Enter (cuidado: no WhatsApp Enter envia).
- `-PasteMax 4000` — limite de caracteres do Ctrl+V.
- `-Relative -RelWidth N -RelHeight N` — plano B se o ponteiro absoluto não funcionar no seu iPhone (precisa calibrar).

## Canal local para automação

Enquanto o script roda, ele aceita comandos em `http://127.0.0.1:47380/` (só no próprio PC, nunca na rede). Do jeito mais simples:

```
powershell -ExecutionPolicy Bypass -File .\iphone-control.ps1 -Send "tap 0.5 0.5"
powershell -ExecutionPolicy Bypass -File .\iphone-control.ps1 -Send "type ola"
powershell -ExecutionPolicy Bypass -File .\iphone-control.ps1 -Send "screenshot"
```

Coordenadas vão de 0 a 1 dentro da área do vídeo (0 0 = canto superior esquerdo). O servidor recusa pedidos sem o header `X-iPhone-Control`, com `Origin` (páginas web) ou com `Host` diferente de `127.0.0.1`/`localhost`. Não há senha: qualquer programa rodando no seu PC consegue mandar comandos enquanto o script estiver aberto.

## Problemas comuns

- **Pareou mas não mexe / mudou de versão do script:** o iOS guarda a descrição antiga do aparelho. No iPhone, **Ajustes > Bluetooth > (i) ao lado do PC > Esquecer Este Dispositivo**, e pareie de novo.
- **Imagem estragada, congelada ou toque caindo no lugar errado:** pare o espelhamento no iPhone e espelhe de novo. Se o toque continuar deslocado, rode `calibrate` no console.
- **Bolinha do AssistiveTouch atrapalhando a tela:** em **Ajustes > Acessibilidade > Toque > AssistiveTouch**, baixe a **Opacidade em Repouso**.
- **iPhone não acha o uxplay-windows:** quase sempre é firewall ou rede marcada como Pública. Confira a regra do `uxplay.exe` em rede Privada.
- **"Anuncio NAO iniciou":** feche outro script ou programa que esteja anunciando como teclado Bluetooth e rode de novo.

## Avisos

- O script instala um **hook global de teclado e mouse** do Windows para capturar cliques e teclas na janela do espelho. Antivírus pode estranhar. Ele só age quando a janela do espelho está em foco; Ctrl+Shift+F12 desliga.
- Os logs ficam em `logs\` e incluem os comandos digitados no console. Não compartilhe essa pasta.

## Licença

MIT, ver [LICENSE](LICENSE). O uxplay-windows é um projeto separado (GPL-3.0), instalado à parte pelo winget; este repositório não inclui código dele.
