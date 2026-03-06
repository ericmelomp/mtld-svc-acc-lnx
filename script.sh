#!/usr/bin/env bash
# Execução: curl -s https://raw.githubusercontent.com/ericmelomp/mtld-svc-acc-lnx/main/script.sh | bash
# Obrigatório: export SSH_KEY="$HOME/.ssh/sua_chave.pem"  (para o executor conectar aos servidores)
# Obrigatório: export MATILDA_SVC_ACC_PASSWORD="senha"     (senha do utilizador matilda-svc-acc nos alvos)
# Opcional: export SVC_ACC_USER="outro_user"  (default: matilda-svc-acc)
# Opcional: export SSH_KEY_PASSPHRASE="senha"  export SERVER_LIST=/caminho/servers.txt
# Acesso nos servidores: utilizador (SVC_ACC_USER) com senha (sem chaves .pem).

set -e

# Quando executado por pipe (curl | bash), o stdin é o próprio script. Qualquer leitura de stdin
# (ex.: ssh-add no fallback) consome o resto do script e o código aparece no ecrã. Gravar o
# script num ficheiro e reexecutar com stdin do terminal evita isso.
if [[ ! -t 0 ]]; then
    SCRIPT_TMP=$(mktemp 2>/dev/null || echo "/tmp/mtld-svc-acc-$$.sh")
    export _MTLD_SCRIPT_TMP="$SCRIPT_TMP"
    cat > "$SCRIPT_TMP"
    if [[ -e /dev/tty ]]; then
        exec bash "$SCRIPT_TMP" 0</dev/tty
    else
        exec bash "$SCRIPT_TMP"
    fi
fi

if [[ -t 1 ]]; then
    R="\033[0m"
    B="\033[1m"
    D="\033[2m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    CYAN="\033[36m"
    MAGENTA="\033[35m"
else
    R=""; B=""; D=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""
fi

# =============================================================================
# VARIÁVEIS OBRIGATÓRIAS (preencher antes de executar)
# =============================================================================
SSH_KEY="${SSH_KEY:-}"                    # Caminho da chave privada para conectar aos servidores
SSH_KEY="${SSH_KEY/#\~/$HOME}"            # Expande ~ para $HOME (Git Bash / Windows)
SERVER_LIST="${SERVER_LIST:-servers.txt}" # Ficheiro com a lista de servidores (um por linha: user@host)

# =============================================================================
# VARIÁVEIS OPCIONAIS (valores por defeito; alterar só se precisar)
# =============================================================================
SSH_KEY_PASSPHRASE="${SSH_KEY_PASSPHRASE:-}"                              # Senha da chave SSH do executor; vazio = pede ao executar
SVC_ACC_USER="${SVC_ACC_USER:-matilda-svc-acc}"                           # Nome do utilizador a criar nos servidores (default: matilda-svc-acc)
MATILDA_SVC_ACC_PASSWORD="${MATILDA_SVC_ACC_PASSWORD:-EdP2#87m62\Z/%eP}"  # Senha do utilizador (SVC_ACC_USER) nos servidores alvo
RESULT_FILE="${RESULT_FILE:-result.txt}"                                  # Ficheiro onde guardar o resultado da execução

# Quando executado via curl|bash não há ficheiro do script; usar ~/tmp/.mtld-svc-acc
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="${HOME}/tmp/.mtld-svc-acc"
    mkdir -p "$SCRIPT_DIR"
fi
# Quando executado via curl|bash, procurar servers.txt em ~/tmp/.mtld-svc-acc
[[ "$SCRIPT_DIR" == "$HOME/tmp/.mtld-svc-acc" ]] && SERVER_LIST="${SERVER_LIST:-$SCRIPT_DIR/servers.txt}"

if [[ ! -f "$SERVER_LIST" ]]; then
    echo -e "${RED}Obrigatório: ficheiro de servidores não encontrado: $SERVER_LIST${R}" >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo -e "${RED}Obrigatório: chave SSH não encontrada: $SSH_KEY${R}" >&2
    echo -e "${D}Defina SSH_KEY com o caminho completo (ex.: export SSH_KEY=\"\$HOME/.ssh/sua_chave.pem\")${R}" >&2
    exit 1
fi
if [[ -z "$MATILDA_SVC_ACC_PASSWORD" ]]; then
    echo -e "${RED}Obrigatório: MATILDA_SVC_ACC_PASSWORD não definida.${R}" >&2
    echo -e "${D}Defina a senha do utilizador $SVC_ACC_USER (ex.: export MATILDA_SVC_ACC_PASSWORD=\"sua_senha\")${R}" >&2
    exit 1
fi

mapfile -t SERVERS < <(grep -v '^[[:space:]]*#' "$SERVER_LIST" | grep -v '^[[:space:]]*$' || true)
if [[ ${#SERVERS[@]} -eq 0 ]]; then
    echo -e "${RED}Obrigatório: nenhum servidor em $SERVER_LIST (adicione um por linha)${R}" >&2
    exit 1
fi

# Senha em base64 para passar ao comando remoto (evita caracteres especiais no shell)
MATILDA_PASS_B64=$(printf '%s' "$MATILDA_SVC_ACC_PASSWORD" | base64 -w 0 2>/dev/null || printf '%s' "$MATILDA_SVC_ACC_PASSWORD" | base64 | tr -d '\n')
SUDOERS_B64=$(printf '%s\n' "Defaults:${SVC_ACC_USER} !requiretty" "${SVC_ACC_USER} ALL=(ALL) NOPASSWD: ALL" | base64 | tr -d '\n')

CMDS=(
    "sudo useradd -m -s /bin/bash $SVC_ACC_USER 2>/dev/null || true"
    "echo \"${SVC_ACC_USER}:\$(echo $MATILDA_PASS_B64 | base64 -d)\" | sudo chpasswd"
    "echo '$SUDOERS_B64' | base64 -d | sudo tee /etc/sudoers.d/$SVC_ACC_USER"
    "sudo chmod 440 /etc/sudoers.d/$SVC_ACC_USER"
    "sudo grep -q '^[^#]*Defaults.*requiretty' /etc/sudoers && sudo cp /etc/sudoers /etc/sudoers.bak.requiretty && sudo sed -i 's/^\([^#]*Defaults.*requiretty\)/# \\1/' /etc/sudoers && sudo visudo -c || true"
    "(sudo sed -i 's/^#* *PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null; sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null); true"
    "(command -v apt-get >/dev/null 2>&1 && sudo apt-get update -qq && sudo apt-get install -y bc net-tools) || (command -v yum >/dev/null 2>&1 && sudo yum install -y bc net-tools) || true"
    "sudo su - $SVC_ACC_USER -c 'sudo whoami'"
    "(sudo netstat -anlp 2>/dev/null; sudo ss -tunlp 2>/dev/null; sudo dmidecode -s system-manufacturer 2>/dev/null; sudo crontab -l 2>/dev/null; sudo route -n 2>/dev/null; sudo readlink -f /proc/1/exe 2>/dev/null; sudo ifconfig -a 2>/dev/null || sudo ip a 2>/dev/null); true"
    "(sudo systemctl enable sshd 2>/dev/null && sudo systemctl start sshd 2>/dev/null) || (sudo systemctl enable ssh 2>/dev/null && sudo systemctl start ssh 2>/dev/null); (sudo systemctl is-active sshd 2>/dev/null || sudo systemctl is-active ssh 2>/dev/null)"
)

if [[ ${#CMDS[@]} -eq 0 ]]; then
    echo -e "${RED}Defina pelo menos um comando no array CMDS.${R}" >&2
    exit 1
fi
CMD="$(printf '%s && ' "${CMDS[@]}" | sed 's/ && $//')"

# Comando para verificar se a máquina já tem o utilizador configurado (evita reconfigurar)
CHECK_ALREADY_CMD='sudo id '"$SVC_ACC_USER"' >/dev/null 2>&1 && sudo grep -q NOPASSWD /etc/sudoers.d/'"$SVC_ACC_USER"' 2>/dev/null'

SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

AGENT_STARTED=
if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
    eval "$(ssh-agent -s)"
    AGENT_STARTED=1
    if [[ -n "$SSH_KEY_PASSPHRASE" ]]; then
        # ssh-add pode ser invocado com ambiente limpo (sem SSH_KEY_PASSPHRASE), por isso
        # gravamos a senha dentro do script askpass (escapada) em vez de usar a variável.
        TMP_ASKPASS=$(mktemp 2>/dev/null || echo /tmp/ssh_askpass_$$)
        # Escapar para uso dentro de single-quoted sh: ' -> '\''
        PP_ESC=$(printf '%s' "$SSH_KEY_PASSPHRASE" | sed "s/'/'\\\\''/g")
        printf '#!/bin/sh\nprintf "%%s" '\''%s'\''\n' "$PP_ESC" > "$TMP_ASKPASS"
        chmod 700 "$TMP_ASKPASS"
        export SSH_ASKPASS="$TMP_ASKPASS"
        export SSH_ASKPASS_REQUIRE=force
        unset DISPLAY
        # Forçar uso do askpass: DISPLAY vazio faz alguns ssh-add ignorarem askpass;
        # usar valor dummy faz ssh-add usar askpass sem tentar abrir X.
        export DISPLAY=dummy:0
        # timeout deve envolver o ssh-add (máx. 15s) para não travar
        ADD_OK=
        if command -v timeout >/dev/null 2>&1; then
            timeout 15 bash -c 'exec 0</dev/null; ssh-add "$SSH_KEY"' 2>/dev/null && ADD_OK=1
        else
            ( exec 0</dev/null; ssh-add "$SSH_KEY" ) 2>/dev/null && ADD_OK=1
        fi
        if [[ -z "$ADD_OK" ]]; then
            # Fallback: ler senha do terminal. Usar </dev/tty para não ler do pipe (evita travar quando curl|bash)
            echo -e "${YELLOW}Não foi possível usar SSH_KEY_PASSPHRASE. Introduza a senha da chave .pem abaixo (cole e Enter). Sem senha? Prima Enter.${R}" >&2
            if [[ -e /dev/tty ]]; then
                ssh-add "$SSH_KEY" < /dev/tty 2>/dev/null || true
            else
                ssh-add "$SSH_KEY" || true
            fi
        fi
        rm -f "$TMP_ASKPASS"
        unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
    else
        if [[ ! -t 0 ]]; then
            echo -e "${RED}Sem TTY e SSH_KEY_PASSPHRASE não definida.${R}" >&2
            echo -e "${D}Defina antes de executar: export SSH_KEY_PASSPHRASE=\"senha_da_chave_pem\"${R}" >&2
            exit 1
        fi
        echo -e "${YELLOW}Introduza a senha da chave .pem (se tiver; sem senha prima Enter):${R}" >&2
        if [[ -e /dev/tty ]]; then
            ssh-add "$SSH_KEY" < /dev/tty
        else
            ssh-add "$SSH_KEY"
        fi
    fi
fi

exec 3>&1
exec 1> >(tee >(sed $'s/\033\\[[0-9;]*m//g' > "$RESULT_FILE") >&3)
exec 2>&1

echo -e "${MAGENTA}"
echo " .d8888b.                                 .d8888b.                    888          "
echo "d88P  Y88b                               d88P  Y88b                   888          "
echo "888    888                               Y88b.                        888          "
echo "888         .d88b.  888d888 .d88b.        \"Y888b.    .d8888b  8888b.  888  .d88b.  "
echo "888        d88\"\"88b 888P\"  d8P  Y8b          \"Y88b. d88P\"        \"88b 888 d8P  Y8b "
echo "888    888 888  888 888    88888888            \"888 888      .d888888 888 88888888 "
echo "Y88b  d88P Y88..88P 888    Y8b.          Y88b  d88P Y88b.    888  888 888 Y8b.     "
echo " \"Y8888P\"   \"Y88P\"  888     \"Y8888        \"Y8888P\"   \"Y8888P \"Y888888 888  \"Y8888  "
echo ""
echo -e "${R}"

RUN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
BOX_W=72
L1="  Configuração remota: utilizador $SVC_ACC_USER (conta de serviço)"
L2="  ${#SERVERS[@]} servidor(es) · ${#CMDS[@]} passos · ${RUN_TIME}"
# Padding até BOX_W para alinhar o canto direito
L1_len=${#L1}
L2_len=${#L2}
L1_pad=$((BOX_W - L1_len))
L2_pad=$((BOX_W - L2_len))
[[ $L1_pad -lt 0 ]] && L1_pad=0
[[ $L2_pad -lt 0 ]] && L2_pad=0
printf -v PAD1 '%*s' "$L1_pad" ''
printf -v PAD2 '%*s' "$L2_pad" ''
# Linha de = sem depender de seq
EQ_LINE=""
for ((i=0;i<BOX_W;i++)); do EQ_LINE="${EQ_LINE}="; done

echo ""
echo -e "${CYAN}${B}+${EQ_LINE}+${R}"
echo -e "${CYAN}${B}|${R}${B}${L1}${R}${PAD1}${CYAN}${B}|${R}"
echo -e "${CYAN}${B}|${R}${B}${L2}${R}${PAD2}${CYAN}${B}|${R}"
echo -e "${CYAN}${B}+${EQ_LINE}+${R}"
echo ""
echo -e "${B}O que será feito em cada servidor:${R}"
echo -e "  ${D}1.${R} Criar utilizador $SVC_ACC_USER (bash, home) com senha"
echo -e "  ${D}2.${R} Configurar sudo sem senha (NOPASSWD) em /etc/sudoers.d/$SVC_ACC_USER"
echo -e "  ${D}3.${R} Comentar Defaults requiretty em /etc/sudoers (se existir)"
echo -e "  ${D}4.${R} Ativar PasswordAuthentication no sshd (login por senha)"
echo -e "  ${D}5.${R} Instalar dependências: bc, net-tools (yum ou apt)"
echo -e "  ${D}6.${R} Testar sudo sem senha (sudo whoami → root)"
echo -e "  ${D}7.${R} Validar comandos: netstat, ss, dmidecode, crontab, route"
echo -e "  ${D}8.${R} Garantir que o serviço SSH está ativo (sshd ou ssh)"
echo -e "  ${D}→ Se o servidor já tiver $SVC_ACC_USER e sudo NOPASSWD, será omitido.${R}"
echo ""
echo -e "  ${D}Chave SSH (conexão do executor):${R} $SSH_KEY"
echo -e "  ${D}Resultado guardado em:${R} $RESULT_FILE"
echo ""

OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL=${#SERVERS[@]}
OK_SERVERS=()
FAIL_SERVERS=()
SKIP_SERVERS=()

for idx in "${!SERVERS[@]}"; do
    server="${SERVERS[idx]}"
    current=$((idx + 1))

    echo -e "${MAGENTA}${B}┌─────────────────────────────────────────────────────────────────────────┐${R}"
    echo -e "${MAGENTA}${B}│${R}  ${B}Servidor ${current}/${TOTAL}${R}  ${CYAN}${server}${R}"
    echo -e "${MAGENTA}${B}└─────────────────────────────────────────────────────────────────────────┘${R}"

    # Verificar se já está configurado
    if ssh "${SSH_OPTS[@]}" "$server" "$CHECK_ALREADY_CMD" 2>/dev/null; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        SKIP_SERVERS+=("$server")
        echo -e "  ${BLUE}${B}⊙ Skipped${R}  $server"
        echo -e "  ${D}→ Utilizador $SVC_ACC_USER e sudo NOPASSWD já existem; nada a fazer.${R}"
        echo ""
        continue
    fi

    echo -e "  ${D}Saída dos comandos no servidor:${R}"
    echo ""

    if ssh "${SSH_OPTS[@]}" "$server" "$CMD"; then
        OK_COUNT=$((OK_COUNT + 1))
        OK_SERVERS+=("$server")
        echo ""
        echo -e "  ${GREEN}${B}✓ Concluído com sucesso${R}  $server"
        echo -e "  ${D}→ Utilizador $SVC_ACC_USER criado (acesso com senha), sudo sem senha ativo, dependências e SSH verificados.${R}"
    else
        ssh_exit=$?
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_SERVERS+=("$server")
        echo ""
        echo -e "  ${RED}${B}✗ Falha${R}  $server (código de saída: $ssh_exit)"
        echo -e "  ${D}→ Verifique a saída acima e a conectividade/permissões no servidor.${R}" >&2
    fi
    echo ""
done

[[ -n "$AGENT_STARTED" && -n "$SSH_AGENT_PID" ]] && kill "$SSH_AGENT_PID" 2>/dev/null || true

echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo -e "  ${B}Resumo da execução${R}"
echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo ""
echo -e "  ${GREEN}${B}Sucesso:${R} ${OK_COUNT}  ${BLUE}${B}Skipped:${R} ${SKIP_COUNT}  ${RED}${B}Falha:${R} ${FAIL_COUNT}  ${B}Total:${R} ${TOTAL}"
echo ""
if [[ ${#OK_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}Servidores configurados (agora):${R}"
    for s in "${OK_SERVERS[@]}"; do echo -e "    ${GREEN}✓${R} $s"; done
    echo ""
fi
if [[ ${#SKIP_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${BLUE}Servidores skipped:${R}"
    for s in "${SKIP_SERVERS[@]}"; do echo -e "    ${BLUE}⊙${R} $s"; done
    echo ""
fi
if [[ ${#FAIL_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${RED}Servidores com falha:${R}"
    for s in "${FAIL_SERVERS[@]}"; do echo -e "    ${RED}✗${R} $s"; done
    echo ""
fi
echo -e "  ${D}Em cada servidor com sucesso: utilizador $SVC_ACC_USER (login por senha), sudo NOPASSWD, bc/net-tools e SSH ativo.${R}"
echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo ""
# Limpar script temporário quando executado via curl|bash (reexec)
[[ -n "${_MTLD_SCRIPT_TMP:-}" && -f "${_MTLD_SCRIPT_TMP}" ]] && rm -f "$_MTLD_SCRIPT_TMP"
