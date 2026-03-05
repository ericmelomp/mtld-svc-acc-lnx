#!/usr/bin/env bash

set -e

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
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-key.pem}"           # Caminho da chave privada para conectar aos servidores
SSH_KEY="${SSH_KEY/#\~/$HOME}"                         # Expande ~ para $HOME (Git Bash / Windows)
SERVER_LIST="${SERVER_LIST:-servers.txt}"              # Ficheiro com a lista de servidores (um por linha: user@host)

# =============================================================================
# VARIÁVEIS OPCIONAIS (valores por defeito; alterar só se precisar)
# =============================================================================
SSH_KEY_PASSPHRASE="${SSH_KEY_PASSPHRASE:-}"          # Senha da chave SSH; vazio = pede ao executar
RESULT_FILE="${RESULT_FILE:-result.txt}"               # Ficheiro onde guardar o resultado da execução
MATILDA_KEY_BASE="${MATILDA_KEY_BASE:-}"              # Caminho base da chave matilda_srv (vazio = pasta do script)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$MATILDA_KEY_BASE" ]]; then
    MATILDA_KEY_BASE="$SCRIPT_DIR/matilda_srv_key"
fi

if [[ ! -f "$SERVER_LIST" ]]; then
    echo -e "${RED}Obrigatório: ficheiro de servidores não encontrado: $SERVER_LIST${R}" >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo -e "${RED}Obrigatório: chave SSH não encontrada: $SSH_KEY${R}" >&2
    echo -e "${D}Defina SSH_KEY com o caminho completo (ex.: export SSH_KEY=\"\$HOME/.ssh/sua_chave.pem\")${R}" >&2
    exit 1
fi

mapfile -t SERVERS < <(grep -v '^[[:space:]]*#' "$SERVER_LIST" | grep -v '^[[:space:]]*$' || true)
if [[ ${#SERVERS[@]} -eq 0 ]]; then
    echo -e "${RED}Obrigatório: nenhum servidor em $SERVER_LIST (adicione um por linha)${R}" >&2
    exit 1
fi

if [[ ! -f "$MATILDA_KEY_BASE" ]]; then
    ssh-keygen -t ed25519 -f "$MATILDA_KEY_BASE" -C "matilda-service-account" -N ""
fi
MATILDA_PUBKEY_FILE="${MATILDA_KEY_BASE}.pub"
if [[ ! -f "$MATILDA_PUBKEY_FILE" ]]; then
    echo -e "${RED}Ficheiro de chave pública não encontrado: $MATILDA_PUBKEY_FILE${R}" >&2
    exit 1
fi
MATILDA_PUBKEY_B64=$(base64 < "$MATILDA_PUBKEY_FILE" | tr -d '\n')
SUDOERS_B64=$(printf '%s\n' 'Defaults:matilda-srv !requiretty' 'matilda-srv ALL=(ALL) NOPASSWD: ALL' | base64 | tr -d '\n')

CMDS=(
    "sudo useradd -m -s /bin/bash matilda-srv 2>/dev/null || true"
    "sudo passwd -l matilda-srv"
    "sudo mkdir -p /home/matilda-srv/.ssh"
    "sudo chmod 700 /home/matilda-srv/.ssh"
    "sudo chown -R matilda-srv:matilda-srv /home/matilda-srv/.ssh"
    "echo '$MATILDA_PUBKEY_B64' | base64 -d | sudo tee /home/matilda-srv/.ssh/authorized_keys"
    "sudo chmod 600 /home/matilda-srv/.ssh/authorized_keys"
    "sudo chown matilda-srv:matilda-srv /home/matilda-srv/.ssh/authorized_keys"
    "echo '$SUDOERS_B64' | base64 -d | sudo tee /etc/sudoers.d/matilda-srv"
    "sudo chmod 440 /etc/sudoers.d/matilda-srv"
    "sudo grep -q '^[^#]*Defaults.*requiretty' /etc/sudoers && sudo cp /etc/sudoers /etc/sudoers.bak.requiretty && sudo sed -i 's/^\([^#]*Defaults.*requiretty\)/# \\1/' /etc/sudoers && sudo visudo -c || true"
    "(command -v apt-get >/dev/null 2>&1 && sudo apt-get update -qq && sudo apt-get install -y bc net-tools) || (command -v yum >/dev/null 2>&1 && sudo yum install -y bc net-tools) || true"
    "sudo su - matilda-srv -c 'sudo -l' && sudo su - matilda-srv -c 'sudo whoami'"
    "(sudo netstat -anlp 2>/dev/null; sudo ss -tunlp 2>/dev/null; sudo dmidecode -s system-manufacturer 2>/dev/null; sudo crontab -l 2>/dev/null; sudo route -n 2>/dev/null; sudo readlink -f /proc/1/exe 2>/dev/null; sudo ifconfig -a 2>/dev/null || sudo ip a 2>/dev/null); true"
    "(sudo systemctl enable sshd 2>/dev/null && sudo systemctl start sshd 2>/dev/null) || (sudo systemctl enable ssh 2>/dev/null && sudo systemctl start ssh 2>/dev/null); (sudo systemctl is-active sshd 2>/dev/null || sudo systemctl is-active ssh 2>/dev/null)"
)

if [[ ${#CMDS[@]} -eq 0 ]]; then
    echo -e "${RED}Defina pelo menos um comando no array CMDS.${R}" >&2
    exit 1
fi
CMD="$(printf '%s && ' "${CMDS[@]}" | sed 's/ && $//')"

SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

AGENT_STARTED=
if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
    eval "$(ssh-agent -s)"
    AGENT_STARTED=1
    if [[ -n "$SSH_KEY_PASSPHRASE" ]]; then
        export SSH_ASKPASS_REQUIRE=force
        export DISPLAY=:0
        TMP_ASKPASS=$(mktemp 2>/dev/null || echo /tmp/ssh_askpass_$$)
        # Askpass que lê a senha da variável (não grava a senha em disco)
        printf '#!/bin/sh\nprintf "%%s" "${SSH_KEY_PASSPHRASE}"\n' > "$TMP_ASKPASS"
        chmod 700 "$TMP_ASKPASS"
        export SSH_ASKPASS="$TMP_ASKPASS"
        # Sem TTY o ssh-add usa SSH_ASKPASS; com TTY às vezes espera teclado e trava
        ( exec 0</dev/null; ssh-add "$SSH_KEY" )
        rm -f "$TMP_ASKPASS"
        unset SSH_ASKPASS SSH_ASKPASS_REQUIRE
    else
        if [[ ! -t 0 ]]; then
            echo -e "${RED}Sem TTY e SSH_KEY_PASSPHRASE não definida. Defina a variável ou execute com terminal interativo.${R}" >&2
            exit 1
        fi
        echo -e "${YELLOW}Introduza a senha da chave (se tiver):${R}"
        ssh-add "$SSH_KEY"
    fi
fi

exec 3>&1
exec 1> >(tee >(sed $'s/\033\\[[0-9;]*m//g' > "$RESULT_FILE") >&3)
exec 2>&1

RUN_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo -e "${CYAN}${B}╔══════════════════════════════════════════════════════════════════════════╗${R}"
echo -e "${CYAN}${B}║${R}  ${B}Configuração remota: utilizador matilda-srv (conta de serviço)${R}                 ${CYAN}${B}║${R}"
echo -e "${CYAN}${B}║${R}  ${#SERVERS[@]} servidor(es) · ${#CMDS[@]} passos · ${RUN_TIME}${R}        ${CYAN}${B}║${R}"
echo -e "${CYAN}${B}╚══════════════════════════════════════════════════════════════════════════╝${R}"
echo ""
echo -e "${B}O que será feito em cada servidor:${R}"
echo -e "  ${D}1.${R} Criar utilizador matilda-srv (bash, home) e bloquear login por senha"
echo -e "  ${D}2.${R} Criar ~/.ssh, implantar chave pública e configurar authorized_keys"
echo -e "  ${D}3.${R} Configurar sudo sem senha (NOPASSWD) em /etc/sudoers.d/matilda-srv"
echo -e "  ${D}4.${R} Comentar Defaults requiretty em /etc/sudoers (se existir)"
echo -e "  ${D}5.${R} Instalar dependências: bc, net-tools (yum ou apt)"
echo -e "  ${D}6.${R} Testar sudo sem senha (sudo whoami → root)"
echo -e "  ${D}7.${R} Validar comandos: netstat, ss, dmidecode, crontab, route"
echo -e "  ${D}8.${R} Garantir que o serviço SSH está ativo (sshd ou ssh)"
echo ""
echo -e "  ${D}Chave SSH (conexão):${R} $SSH_KEY"
echo -e "  ${D}Chave matilda-srv (deploy):${R} $MATILDA_PUBKEY_FILE"
echo -e "  ${D}Resultado guardado em:${R} $RESULT_FILE"
echo ""

OK_COUNT=0
FAIL_COUNT=0
TOTAL=${#SERVERS[@]}
OK_SERVERS=()
FAIL_SERVERS=()

for idx in "${!SERVERS[@]}"; do
    server="${SERVERS[idx]}"
    current=$((idx + 1))

    echo -e "${MAGENTA}${B}┌─────────────────────────────────────────────────────────────────────────┐${R}"
    echo -e "${MAGENTA}${B}│${R}  ${B}Servidor ${current}/${TOTAL}${R}  ${CYAN}${server}${R}"
    echo -e "${MAGENTA}${B}└─────────────────────────────────────────────────────────────────────────┘${R}"
    echo -e "  ${D}Saída dos comandos no servidor:${R}"
    echo ""

    if ssh "${SSH_OPTS[@]}" "$server" "$CMD"; then
        OK_COUNT=$((OK_COUNT + 1))
        OK_SERVERS+=("$server")
        echo ""
        echo -e "  ${GREEN}${B}✓ Concluído com sucesso${R}  $server"
        echo -e "  ${D}→ Utilizador matilda-srv criado, chave implantada, sudo sem senha ativo, dependências e SSH verificados.${R}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_SERVERS+=("$server")
        echo ""
        echo -e "  ${RED}${B}✗ Falha${R}  $server (código de saída: $?)"
        echo -e "  ${D}→ Verifique a saída acima e a conectividade/permissões no servidor.${R}" >&2
    fi
    echo ""
done

[[ -n "$AGENT_STARTED" && -n "$SSH_AGENT_PID" ]] && kill "$SSH_AGENT_PID" 2>/dev/null || true

echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo -e "  ${B}Resumo da execução${R}"
echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo ""
echo -e "  ${GREEN}${B}Sucesso:${R} ${OK_COUNT}  ${RED}${B}Falha:${R} ${FAIL_COUNT}  ${B}Total:${R} ${TOTAL}"
echo ""
if [[ ${#OK_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}Servidores configurados:${R}"
    for s in "${OK_SERVERS[@]}"; do echo -e "    ${GREEN}✓${R} $s"; done
    echo ""
fi
if [[ ${#FAIL_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${RED}Servidores com falha:${R}"
    for s in "${FAIL_SERVERS[@]}"; do echo -e "    ${RED}✗${R} $s"; done
    echo ""
fi
echo -e "  ${D}Em cada servidor com sucesso: utilizador matilda-srv, chave SSH, sudo NOPASSWD, bc/net-tools e SSH ativo.${R}"
echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo ""
