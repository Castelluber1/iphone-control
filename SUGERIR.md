# Sugestão de resposta (sugerir.ps1)

Tira um print da conversa aberta no iPhone (pelo canal local do `iphone-control.ps1`), manda pro **Codex CLI** conectado à conta ChatGPT e devolve **uma** sugestão de resposta. A sugestão vai pro clipboard do Windows e aparece numa janela editável (sempre no topo) com **Copiar** e **Fechar**. O script **nunca envia nada ao iPhone**: você clica no campo do WhatsApp no espelho, dá Ctrl+V, revisa e envia.

## Uso

Com o `iphone-control.ps1` rodando e a conversa aberta no espelho:

```
powershell -ExecutionPolicy Bypass -File .\sugerir.ps1
powershell -ExecutionPolicy Bypass -File .\sugerir.ps1 -Instrucao "mais formal"
powershell -ExecutionPolicy Bypass -File .\sugerir.ps1 -Image C:\caminho\print.png
```

Opções:

- `-Instrucao "..."`: pedido extra só para esta resposta (ex.: "mais curta", "recusa com educação").
- `-Image arquivo.png`: usa um print pronto em vez de pedir ao canal local (o arquivo não é apagado).
- `-CodexPath C:\...\codex.exe` ou variável de ambiente `CODEX_PATH`. Sem isso, o script procura a versão mais nova em `%USERPROFILE%\.vscode\extensions\openai.chatgpt-*\bin\windows-x86_64\codex.exe` e depois no PATH.
- `-TimeoutSec 120`: tempo máximo de espera pelo Codex.
- `-SemJanela`: só põe no clipboard, sem janelas.

Contexto fixo opcional: crie `sugerir-contexto.txt` na pasta do repositório (fica fora do git) com o que o Codex deve saber sempre, por exemplo como você costuma escrever. O conteúdo vai junto em todo pedido.

Como o Codex é chamado: `codex exec -i <print.png> --skip-git-repo-check --sandbox read-only --ephemeral --color never -C <pasta vazia> -o <saida.txt> -`, com o prompt pelo stdin, a partir de uma pasta vazia em `.tmp\`. A pasta e o print que o script pediu são apagados no fim. O log (`logs\sugerir-AAAAMMDD.log`) guarda só hora, tempo, status e tamanho da sugestão, nunca o texto.

O prompt pede resposta curta, em português, no seu tom, sem inventar fatos, números, preços ou prazos. Quando falta informação, vem uma pergunta ou um `[colchete]` para você preencher. Mesmo assim, **revise antes de enviar**.

## Privacidade

- **O print inteiro da tela vai para os servidores da OpenAI.** Tudo o que aparece nele (nomes, números de telefone, fotos de perfil, o texto das mensagens, notificações que estiverem na tela) sai do seu PC.
- **Conversa de cliente vira dado de cliente enviado a um terceiro (OpenAI), sem o cliente saber.** Se o cliente mandou documento, dado de imigração, valor ou informação pessoal, isso foi junto. Avalie se isso é aceitável para você e para as obrigações que você tem com seus clientes antes de usar em conversas de trabalho.
- O tratamento desse dado segue as regras da sua conta ChatGPT (incluindo a configuração de uso para treinamento), não as deste script. `--ephemeral` só evita que o Codex grave a sessão no seu disco; não muda o que acontece no servidor.
- O conteúdo de `sugerir-contexto.txt` também é enviado em todo pedido.
