# matilda-srv-acc-lnx

Configuração remota da **conta de serviço matilda-srv** em servidores Linux target, para uso com **Matilda Cloud** (Discovery / Migrate). O script conecta via SSH a uma lista de servidores e aplica, em cada um, os pré-requisitos definidos no Matilda Cloud Tool Installation Guide.

---

## Índice

- [Quick start](#quick-start)
- [O que o script faz](#o-que-o-script-faz)
- [Requisitos](#requisitos)
- [Ficheiros](#ficheiros)
- [Configuração](#configuração)
- [Utilização](#utilização)
- [Saída e resultado](#saída-e-resultado)
- [Segurança](#segurança)
- [Resolução de problemas](#resolução-de-problemas)
- [Conformidade Matilda Cloud](#conformidade-matilda-cloud)
- [Exemplo](#exemplo)

---

## Quick start

1. Coloque em `servers.txt` os servidores (um por linha), no formato `user@host`.
2. Ajuste no script, se necessário: `SSH_KEY` (chave para conectar) e `SERVER_LIST`.
3. Execute:

   ```bash
   chmod +x script.sh
   ./script.sh
   ```

4. Consulte o resumo no terminal e o log completo em `result.txt`.

A chave SSH para a conta **matilda-srv** é criada automaticamente na primeira execução (`matilda_srv_key` / `matilda_srv_key.pub`) se não existir.

---

## O que o script faz

Em **cada servidor** da lista, o script executa sequencialmente:

| Passo | Descrição |
|-------|-----------|
| 1 | Cria o utilizador `matilda-srv` (bash, home) e bloqueia login por senha (`passwd -l`). |
| 2 | Cria `~/.ssh`, implanta a chave pública e configura `authorized_keys`. |
| 3 | Configura sudo sem senha em `/etc/sudoers.d/matilda-srv` (NOPASSWD, !requiretty). |
| 4 | Comenta a linha `Defaults requiretty` em `/etc/sudoers` (se existir). |
| 5 | Instala dependências: `bc` e `net-tools` (yum ou apt, conforme a distro). |
| 6 | Testa sudo sem senha (ex.: `sudo whoami` como matilda-srv → root). |
| 7 | Valida comandos exigidos pelo Discovery: netstat/ss, dmidecode, crontab -l, route -n, readlink, ifconfig/ip. |
| 8 | Garante que o serviço SSH está ativo (sshd ou ssh). |

Os comandos são encadeados com `&&`; se um falhar, os seguintes não correm nesse servidor. A saída é mostrada no terminal (com cores) e guardada em texto limpo em `result.txt`.

---

## Requisitos

- **Bash** 4+ (para `mapfile` e process substitution).
- **SSH** (cliente OpenSSH) no `PATH`.
- Acesso aos servidores: a chave indicada em `SSH_KEY` deve estar autorizada (ex.: em `~/.ssh/authorized_keys` do utilizador usado em `user@host`) e esse utilizador deve poder executar `sudo` nos comandos do script.

**Ambientes testados:** Linux, macOS, Git Bash / WSL no Windows.

**Distros target suportadas:** RHEL/CentOS/OEL (yum), Ubuntu/Debian (apt). Amazon Linux compatível.

---

## Ficheiros

| Ficheiro | Descrição |
|----------|-----------|
| `script.sh` | Script principal. Contém as variáveis de configuração e o array de comandos (normalmente não é preciso alterar os comandos para o caso de uso Matilda). |
| `servers.txt` | Lista de servidores, um por linha: `user@host` ou só `host`. Linhas vazias e comentários (`#`) são ignorados. |
| `result.txt` | Gerado em cada execução com toda a saída em texto limpo (sem códigos de cor). Nome alterável via `RESULT_FILE`. |
| `matilda_srv_key` / `matilda_srv_key.pub` | Par de chaves da conta matilda-srv. Criados automaticamente na primeira execução se não existirem; a chave pública é implantada em todos os target. |

---

## Configuração

### Variáveis obrigatórias (verificar antes de executar)

| Variável | Valor por defeito | Descrição |
|----------|-------------------|-----------|
| `SSH_KEY` | `$HOME/.ssh/ec2-key.pem` | Caminho da chave privada usada para **conectar** aos servidores (user em servers.txt). |
| `SERVER_LIST` | `servers.txt` | Ficheiro com a lista de servidores. |

### Variáveis opcionais

| Variável | Valor por defeito | Descrição |
|----------|-------------------|-----------|
| `SSH_KEY_PASSPHRASE` | (vazio) | Senha da chave SSH; se vazia, o script pede uma vez ao iniciar. |
| `RESULT_FILE` | `result.txt` | Ficheiro onde guardar o resultado da execução. |
| `MATILDA_KEY_BASE` | (pasta do script) | Caminho base para o par de chaves matilda-srv (`matilda_srv_key` / `.pub`). |

**Exemplo por ambiente:**

```bash
export SSH_KEY="$HOME/.ssh/minha_chave"
export SSH_KEY_PASSPHRASE="minha_senha"
export SERVER_LIST="produção.txt"
export RESULT_FILE="resultado-$(date +%Y%m%d).txt"
./script.sh
```

### Formato de `servers.txt`

```text
user@servidor1.exemplo.com
user@servidor2.exemplo.com
192.168.1.10
```

Comentários permitidos:

```text
# Produção
admin@svr-prod-01.empresa.com
# Teste
user@teste.empresa.com
```

---

## Utilização

1. **Lista de servidores**  
   Edite `servers.txt` com um endereço por linha (`user@host` ou `host`).

2. **Chave SSH de conexão**  
   Defina `SSH_KEY` no script ou com `export SSH_KEY="/caminho/para/chave"`. Confirme que a chave está autorizada em cada servidor para o utilizador indicado.

3. **Executar**  
   ```bash
   chmod +x script.sh
   ./script.sh
   ```

4. **Resultado**  
   Ver o resumo no terminal e o log completo em `result.txt`.

Não é necessário editar o array `CMDS` no script para o fluxo padrão de configuração da conta matilda-srv; só altere se quiser personalizar ou adicionar passos.

---

## Saída e resultado

- **Terminal:** Cabeçalho com data/hora, resumo do que será feito (8 passos), lista de servidores e comandos; para cada servidor, caixa com “Servidor X/Y”, saída dos comandos e indicação **✓ Concluído** ou **✗ Falha**; no final, resumo com listas de servidores com sucesso e com falha.
- **Cores:** Ativas apenas quando a saída é um terminal; em redirecionamentos a saída é texto puro.
- **result.txt:** Mesmo conteúdo do ecrã, sem códigos ANSI, sobrescrito em cada execução. Para outro ficheiro: `RESULT_FILE=outro.txt ./script.sh`.

---

## Segurança

- Use uma chave SSH dedicada para conexão aos target, com permissões restritas (ex.: `chmod 600`).
- Não versionar chaves privadas nem passphrase no script; preferir variáveis de ambiente ou prompt.
- Os comandos correm com os privilégios do utilizador SSH no servidor (e sudo quando aplicável); reveja os passos antes de usar em produção.

---

## Resolução de problemas

| Problema | Possível causa / solução |
|----------|---------------------------|
| "Defina pelo menos um comando no array CMDS" | O array `CMDS` está vazio no script; não deveria acontecer no conteúdo padrão. |
| "Ficheiro de servidores não encontrado" | O ficheiro em `SERVER_LIST` não existe; crie `servers.txt` ou ajuste a variável. |
| "Chave SSH não encontrada" | O caminho em `SSH_KEY` está errado ou a chave não existe. Use caminho absoluto ou `$HOME/.ssh/...`. |
| Falha de conexão SSH (timeout, refused) | Rede, firewall ou endereço em `servers.txt` incorreto; confirme porta 22 acessível. |
| "Permission denied (publickey)" | A chave em `SSH_KEY` não está em `~/.ssh/authorized_keys` do utilizador usado em `user@host`. |
| Pedir passphrase em cada servidor | Defina `SSH_KEY_PASSPHRASE` ou introduza a passphrase quando o script pedir (usa ssh-agent). |
| Host key verification failed | O script já usa `StrictHostKeyChecking=accept-new`; na primeira ligação a chave do host é aceite. |
| result.txt vazio ou incompleto | Em alguns ambientes a escrita pode atrasar; aguarde ou verifique permissões na pasta. |

---

## Conformidade Matilda Cloud

O script foi validado face ao **Matilda Cloud Tool Installation Guide** (Single Instance) para **Linux Target Servers** (Pre-requisites on Linux Target Servers e Matilda Discovery Commands list).

### Requisitos do guia vs script

| # | Requisito do guia | No script |
|---|-------------------|-----------|
| 1 | Criar conta de serviço (matilda-srv) | `useradd -m -s /bin/bash matilda-srv`, `passwd -l` |
| 2 | Sudo sem senha para comandos Discovery | `/etc/sudoers.d/matilda-srv`: NOPASSWD: ALL |
| 3 | Comentar "Defaults requiretty" em `/etc/sudoers` | `sed` + backup + `visudo -c` |
| 4 | Defaults !requiretty para matilda-srv | Incluído em sudoers.d |
| 5 | Acesso de leitura (via sudo) | NOPASSWD: ALL |
| 6 | Comando `bc` disponível | Instalação via yum/apt |
| 7 | net-tools (netstat, ifconfig, route) | Incluído em net-tools |
| 8 | Login SSH da conta matilda-srv (porta 22) | `.ssh`, `authorized_keys`, serviço SSH ativo |
| 9 | Serviço SSH ativo no target | systemctl enable/start sshd ou ssh |

### Comandos Discovery (Linux)

O guia exige que matilda-srv execute com sudo sem senha: netstat/ss, dmidecode, ifconfig/ip, crontab -l, readlink, route -n. O script valida a execução destes comandos após a configuração.

**Nota (guia p. 10):** Para discovery mais detalhado (Apache, Nginx, Tomcat, Jboss, Kubernetes, WebLogic, etc.), o guia recomenda adicionar matilda-srv aos grupos de sistema necessários para leitura dos ficheiros de configuração; isso fica fora do âmbito deste script.

*Referência: Matilda Cloud Tool Installation Guide – Single Instance (10132025), secções “Pre-requisites on Linux Target Servers” e “Matilda Discovery Commands list - Linux/UNIX”.*

---

## Exemplo

**servers.txt:**

```text
ec2-user@100.54.138.193
ec2-user@100.27.6.114
```

**Execução:**

```bash
./script.sh
```

**Resumo típico no final:**

```text
Sucesso: 2  Falha: 0  Total: 2
Servidores configurados:
  ✓ ec2-user@100.54.138.193
  ✓ ec2-user@100.27.6.114
```

O log completo (incluindo a saída de cada comando em cada servidor) fica em `result.txt`.
