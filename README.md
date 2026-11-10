# iphone-control

Controle o iPhone pelo PC com Windows: a tela do iPhone aparece numa janela do PC (espelhamento AirPlay) e o mouse e o teclado do PC passam a tocar, arrastar e digitar no iPhone.

Como funciona:

- **Imagem:** o [uxplay-windows](https://github.com/leapbtw/uxplay-windows) recebe o "Espelhar Tela" do iPhone pelo Wi-Fi e abre a janela **AirPlay Video Stream**.
- **Controle:** o script `iphone-control.ps1` faz o PC se apresentar ao iPhone como um **teclado + mouse Bluetooth LE** (HID). Clique na janela do espelho vira toque no iPhone; o teclado do PC digita no iPhone.

Não instala nada além do uxplay-windows: usa só o PowerShell 5.1 e o compilador C# do .NET Framework 4, que já vêm no Windows.

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
5. Dois cliques no **`instalar.bat`**, uma vez. Ele gera o painel `bin\iPhoneControl.exe` a partir de `app\iPhoneControl.cs` (com o compilador que já vem no Windows) e cria o atalho **iPhone Control** na Área de Trabalho e no Menu Iniciar. Depois de atualizar o repositório (`git pull`), rode o `instalar.bat` de novo: ele fecha o painel aberto e gera o novo. O `.exe` não vai para o git.

**Dia a dia: abra pelo ícone iPhone Control.** O painel liga o espelho com as opções recomendadas (decodificação por software, que evita a imagem estragada em placas Intel; desliga o "Bluetooth Discovery" do uxplay-windows), abre o uxplay-windows se estiver fechado e roda o controle escondido, sem janela de terminal.

## Painel (iPhone Control)

- **Status ao vivo:** *Conectado* (verde), *Sem iPhone* (cinza, mostra o nome do PC para parear), *Espelho fechado* (vermelho), *Iniciando* e *Parado*.
- **Botões:** Voltar, Home, Apps; campo **Abrir app** (digite o nome e Enter, igual ao `abrir <nome>`); **Sugerir** (roda o `sugerir.ps1`); **Respostas** (menu com as do `respostas.txt`, mais "Editar respostas…"); interruptores **Captura do mouse e teclado** e **Espelho sempre no topo**; **Pasta de logs**.
- **Fechar (X) não desliga:** o painel vai para a bandeja (perto do relógio). Clique no ícone para abrir de novo; botão direito: Abrir, Sugerir resposta, **Sair**. Só o *Sair* encerra o controle. Não inicia junto com o Windows.
- Se o controle cair, o painel reinicia sozinho (até 3 vezes por minuto). Depois disso mostra *Parado* com a última linha do log; clique no selo para tentar de novo.
- Se um controle já estiver aberto no terminal, o painel usa ele em vez de abrir outro.
- Segue o tema claro/escuro do Windows. Erros do painel ficam em `logs\painel-erro-AAAAMMDD.log`.
- `iPhoneControl.exe --sair` fecha o painel aberto (o mesmo que bandeja > Sair).

**Modo terminal (continua funcionando):** dois cliques no `iniciar.bat` fazem o mesmo num terminal, com o console de comandos. Repassa argumentos ao `iphone-control.ps1` (ex.: `iniciar.bat -Relative`). Não use os dois ao mesmo tempo.

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
| **Ctrl+Shift+F10** | Liga/desliga "afixar na altura da tela" |
| **Esc** durante um Ctrl+V longo | Cancela a digitação |
| **Esc** (fora de um colar) | Voltar: toca no botão "<" do canto superior esquerdo |
| **Ctrl+Shift+1** a **9** | Digita a resposta pronta 1 a 9 do `respostas.txt` (nunca aperta Enter) |
| **Ctrl+Shift+S** | Abre o `sugerir.ps1` em segundo plano (sugestão de resposta, ver [SUGERIR.md](SUGERIR.md)) |

Um selo **CONTROLE LIGADO / DESLIGADO** aparece na barra de título do espelho.

**Afixar na altura da tela** (ligado por padrão): quando a janela do espelho aparece, ou quando o vídeo gira entre retrato e paisagem, ela é encaixada na área útil do monitor onde está (acima da barra de tarefas): altura da tela menos uma margem pequena, largura pela proporção do vídeo, topo encostado no topo, mesma posição horizontal. Se você mover ou redimensionar na mão, o script só mexe quando a janela sai da área útil. `-NoFit` desliga; no console, `fit` reencaixa agora e `fit on` / `fit off` liga e desliga.

O primeiro clique numa janela sem foco só dá foco a ela (e também conta como toque).

No console do script dá para digitar comandos (`help` lista todos): texto solto digita no iPhone, `tap 0.5 0.5`, `swipe ...`, `home`, `status`, `q` para sair.

Atalhos de navegação (console e canal local):

- `abrir whatsapp` — vai para a tela inicial, abre a busca (Cmd+Espaço), digita o nome e aperta Enter no primeiro resultado. Teste primeiro com a tela inicial aberta: se a busca não abrir no seu iPhone, o nome é digitado onde estiver o cursor.
- `voltar` — toca no "<" do canto superior esquerdo (mesmo que o Esc). A posição muda de app para app: `voltar 0.06 0.08` usa outra posição só dessa vez, e `-BackX` / `-BackY` muda o padrão. O deslize da borda esquerda não funciona com o ponteiro do AssistiveTouch.
- `apps` — alternador de apps (desliza da base até o meio e segura).
- `sugerir` — o mesmo que Ctrl+Shift+S.

**Respostas prontas:** na primeira vez o script cria o `respostas.txt` a partir do `respostas.exemplo.txt`. Uma resposta por linha, `nome = texto`. No console, `/r` lista as respostas e `/r nome` digita uma; com o espelho em foco, Ctrl+Shift+1..9 digita a 1ª..9ª da lista. O texto é só digitado; quem confere e aperta Enter é você. O arquivo é lido de novo a cada uso (pode editar com o script aberto) e fica fora do git.

**Proporção do vídeo:** a proporção confirmada do iPhone fica salva em `.tmp\proporcao.txt` e é usada logo ao abrir, antes da detecção. A detecção por faixas pretas continua rodando e manda; quando a leitura chega perto do valor salvo (retrato ou paisagem), usa o salvo exato.

**Dedo preso:** se o "soltar" do clique se perder (Win+L, UAC, troca de janela no meio de um arraste), o script solta o dedo no iPhone sozinho e avisa no console.

Opções úteis:

- `-NoFit` — não encaixa a janela do espelho na altura da tela.
- `-PasteNewlines` — no Ctrl+V, quebra de linha vira Enter (cuidado: no WhatsApp Enter envia).
- `-PasteMax 4000` — limite de caracteres do Ctrl+V.
- `-WheelThreshold 40` — rodinha: soma de movimento para o primeiro deslize de uma rajada (depois 1 deslize a cada 120, que é um "clique" de rodinha comum). Ajuda em mouse de rolagem fina, que manda movimentos pequenos.
- `-Headless` — sem console: comandos só pelo canal local (é como o painel roda o controle). `quit` pelo canal encerra.
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
- **Rodinha não rola:** mouse de rolagem fina manda movimentos pequenos; o padrão já rola a partir de 40. Se ainda falhar, tente `-WheelThreshold 20`. A cada rajada da rodinha o console mostra uma linha `Rodinha: ...` dizendo se foi para o iPhone ou por que foi ignorada (captura desligada, fora da área de vídeo, outra janela por cima).
- **Imagem estragada, congelada ou toque caindo no lugar errado:** pare o espelhamento no iPhone e espelhe de novo. Se o toque continuar deslocado, rode `calibrate` no console.
- **Bolinha do AssistiveTouch atrapalhando a tela:** em **Ajustes > Acessibilidade > Toque > AssistiveTouch**, baixe a **Opacidade em Repouso**.
- **iPhone não acha o uxplay-windows:** quase sempre é firewall ou rede marcada como Pública. Confira a regra do `uxplay.exe` em rede Privada.
- **"Anuncio NAO iniciou":** feche outro script ou programa que esteja anunciando como teclado Bluetooth e rode de novo.

## Avisos

- O script instala um **hook global de teclado e mouse** do Windows para capturar cliques e teclas na janela do espelho. Antivírus pode estranhar. Ele só age quando a janela do espelho está em foco; Ctrl+Shift+F12 desliga.
- Os logs ficam em `logs\` e incluem os comandos digitados no console. Não compartilhe essa pasta.

## Licença

MIT, ver [LICENSE](LICENSE). O uxplay-windows é um projeto separado (GPL-3.0), instalado à parte pelo winget; este repositório não inclui código dele.
