# mtld-svc-acc-lnx

Configuração remota da **conta de serviço** em servidores Linux (utilizador com acesso por **senha**, sem chaves .pem nos alvos), para uso com **Matilda Cloud** (Discovery / Migrate). O script conecta via SSH a uma lista de servidores e aplica os pré-requisitos em cada um.

---

## Índice

- [Quick start](#quick-start)
- [O que o script faz](#o-que-o-script-faz)
- [Requisitos](#requisitos)
- [Variáveis (export)](#variáveis-export)
- [Ficheiros](#ficheiros)
- [Utilização](#utilização)
- [Saída e resultado](#saída-e-resultado)
- [Resolução de problemas](#resolução-de-problemas)

---

## Quick start

1. **Definir variáveis** (obrigatório usar `export`; o script não pede senha no terminal):

   ```bash
   export SSH_KEY='$HOME/.ssh/sua_chave.pem'
   export SSH_KEY_PASSPHRASE='senha_da_chave_pem'
   export MATILDA_SVC_ACC_PASSWORD='senha_do_utilizador_nos_servidores'
   ```

2. **Lista de servidores**: ficheiro com um `user@host` por linha (ex.: `servers.txt` no diretório atual ou `~/tmp/.mtld-svc-acc/servers.txt` quando executado via `curl|bash`).

3. **Executar**:

   ```bash
   curl -s https://raw.githubusercontent.com/ericmelomp/mtld-svc-acc-lnx/main/script.sh | bash
   ```

   Ou, com o repositório clonado:

   ```bash
   chmod +x script.sh
   ./script.sh
   ```

4. Consultar o resumo no terminal e o log completo em `result.txt`.

---

## O que o script faz

Em **cada servidor** da lista, o script:

| Passo | Descrição |
|-------|-----------|
| 1 | Cria o utilizador (default: `matilda-svc-acc`) com bash e home, e define a senha. |
| 2 | Configura sudo sem senha em `/etc/sudoers.d/<utilizador>` (NOPASSWD, !requiretty). |
| 3 | Comenta `Defaults requiretty` em `/etc/sudoers` (se existir). |
| 4 | Ativa `PasswordAuthentication` no sshd (login por senha). |
| 5 | Instala dependências: `bc` e `net-tools` (yum ou apt). |
| 6 | Testa sudo sem senha (`sudo whoami` → root). |
| 7 | Garante que o serviço SSH está ativo (sshd ou ssh). |

- **Acesso nos servidores:** utilizador + senha (sem chaves .pem).
- Se o servidor **já tiver** o utilizador e sudo NOPASSWD configurados, é **omitido** (Skipped).
- A saída é mostrada no terminal (com cores) e guardada em texto limpo em `result.txt`.

---

## Requisitos

- **Bash** 4+ (mapfile, process substitution).
- **SSH** (cliente OpenSSH) no `PATH`.
- Acesso aos servidores: a chave em `SSH_KEY` deve estar autorizada (ex.: em `~/.ssh/authorized_keys` do utilizador usado em `user@host`) e esse utilizador deve poder executar `sudo`.

**Ambientes testados:** Linux, macOS, Git Bash / WSL.

**Distros alvo:** RHEL/CentOS/OEL (yum), Ubuntu/Debian (apt). Amazon Linux compatível.

---

## Variáveis (export)

O script **só funciona com variáveis definidas por export**; não solicita senha no terminal.

### Obrigatórias

| Variável | Descrição |
|----------|-----------|
| `SSH_KEY` | Caminho da chave .pem usada para **conectar** aos servidores (utilizador em `servers.txt`). |
| `SSH_KEY_PASSPHRASE` | Senha da chave .pem. |
| `MATILDA_SVC_ACC_PASSWORD` | Senha do utilizador criado nos servidores (nome definido por `SVC_ACC_USER`). |

### Opcionais

| Variável | Valor por defeito | Descrição |
|----------|-------------------|-----------|
| `SVC_ACC_USER` | `matilda-svc-acc` | Nome do utilizador a criar em cada servidor. |
| `SERVER_LIST` | `servers.txt` ou `~/tmp/.mtld-svc-acc/servers.txt` | Ficheiro com a lista de servidores (um por linha: `user@host`). |
| `RESULT_FILE` | `result.txt` | Ficheiro onde guardar o resultado da execução. |

### Exemplo (aspas simples)

```bash
export SSH_KEY='$HOME/.ssh/minha_chave.pem'
export SSH_KEY_PASSPHRASE='senha_da_chave'
export MATILDA_SVC_ACC_PASSWORD='senha_do_servico'
export SVC_ACC_USER='matilda-svc-acc'
export SERVER_LIST='servers.txt'
curl -s https://raw.githubusercontent.com/ericmelomp/mtld-svc-acc-lnx/main/script.sh | bash
```

---

## Ficheiros

| Ficheiro | Descrição |
|----------|-----------|
| `script.sh` | Script principal. Variáveis via export; não editar senhas no script. |
| `servers.txt` | Lista de servidores, um por linha: `user@host`. Linhas vazias e comentários (`#`) são ignorados. Por defeito no cwd ou em `~/tmp/.mtld-svc-acc/` quando executado via `curl | bash`. |
| `result.txt` | Gerado em cada execução com toda a saída em texto limpo (sem códigos de cor). Nome alterável via `RESULT_FILE`. |

---

## Utilização

1. **Lista de servidores**  
   Crie ou edite o ficheiro indicado em `SERVER_LIST` com um endereço por linha (`user@host`).

2. **Variáveis**  
   Defina `SSH_KEY`, `SSH_KEY_PASSPHRASE` e `MATILDA_SVC_ACC_PASSWORD` (e opcionalmente `SVC_ACC_USER`, `SERVER_LIST`) com `export` antes de executar.

3. **Executar**  
   Via curl (recomendado) ou localmente:
   ```bash
   curl -s https://raw.githubusercontent.com/ericmelomp/mtld-svc-acc-lnx/main/script.sh | bash
   ```
   ou
   ```bash
   ./script.sh
   ```

4. **Resultado**  
   Resumo no terminal (Sucesso / Skipped / Falha) e log completo em `result.txt`.

---

## Saída e resultado

- **Terminal:** Cabeçalho, resumo do que será feito, por cada servidor: caixa “Servidor X/Y”, saída dos comandos, e indicação **✓ Concluído**, **⊙ Skipped** ou **✗ Falha**; no final, resumo com contagens e listas.
- **Cores:** Ativas apenas quando a saída é um terminal.
- **result.txt:** Mesmo conteúdo do ecrã, sem códigos ANSI, sobrescrito em cada execução.

---

## Resolução de problemas

| Problema | Possível causa / solução |
|----------|---------------------------|
| "Ficheiro de servidores não encontrado" | O ficheiro em `SERVER_LIST` não existe. Crie `servers.txt` ou defina `export SERVER_LIST='...'`. |
| "Chave SSH não encontrada" | Caminho em `SSH_KEY` incorreto ou chave inexistente. Use `export SSH_KEY='...'` com caminho absoluto. |
| "MATILDA_SVC_ACC_PASSWORD não definida" | Defina `export MATILDA_SVC_ACC_PASSWORD='...'`. |
| "Obrigatório: defina SSH_KEY_PASSPHRASE" | A chave .pem tem senha; defina `export SSH_KEY_PASSPHRASE='...'`. O script não pede senha no terminal. |
| "Não foi possível adicionar a chave com SSH_KEY_PASSPHRASE" | Senha ou caminho da chave incorretos. Verifique e use export. |
| Falha de conexão SSH (timeout, refused) | Rede, firewall ou endereço em `servers.txt`; confirme porta 22. |
| "Permission denied (publickey)" | A chave em `SSH_KEY` não está em `~/.ssh/authorized_keys` do utilizador em `user@host`. |
| Host key verification failed | O script usa `StrictHostKeyChecking=accept-new`; na primeira ligação a chave do host é aceite. |

---

*Referência: Matilda Cloud Tool Installation Guide – pré-requisitos em Linux Target Servers.*
