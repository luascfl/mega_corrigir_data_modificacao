#!/bin/bash

# ==============================================================================
# Script de Processamento em Lote (v13 - CORREÇÃO DEFINITIVA)
# ==============================================================================

# --- CONFIGURAÇÃO ---
REMOTE_PATH="Mega:Uploads do MEGA"
MAX_BATCH_SIZE_GB=5
# --------------------

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BATCH_DIR="$SCRIPT_DIR/Mega_Batch_Temp"
MASTER_LIST_FILE="$SCRIPT_DIR/mega_master_list.jsonl"
BATCH_FILE_LIST="$SCRIPT_DIR/mega_batch_list.txt"
SCRIPT_START_EPOCH=$(date +%s)              # utilizado para detectar arquivos ainda não corrigidos
SCRIPT_START_CUTOFF="@${SCRIPT_START_EPOCH}"

# Arquivos de Log
LOG_SUCCESS="$SCRIPT_DIR/_log_success.txt"
LOG_FAILED="$SCRIPT_DIR/_log_failed_patterns.txt"
LOG_IGNORE="$SCRIPT_DIR/_log_ignore.txt"
DOWNLOAD_LOG_FILE="$SCRIPT_DIR/rclone_download.log"
UPLOAD_LOG_FILE="$SCRIPT_DIR/rclone_upload.log"
LSJSON_LOG_FILE="$SCRIPT_DIR/rclone_lsjson.log"

# Convertendo GB para Bytes
MAX_BATCH_SIZE_BYTES=$((MAX_BATCH_SIZE_GB * 1024 * 1024 * 1024))

mkdir -p "$BATCH_DIR"
echo "Diretório de lote: $BATCH_DIR"

touch "$LOG_SUCCESS" "$LOG_FAILED" "$LOG_IGNORE"

# ------------------------------------------------------------------------------
# Função Plano B (Correção por Nome)
# ------------------------------------------------------------------------------
run_plan_b_fix() {
    local target_dir="$1"
    local log_success_file="$2"
    local log_failed_file="$3"
    
    echo "--- Iniciando Plano B (Correção por Nome) ---"
    
    find "$target_dir" -type f -newermt "$SCRIPT_START_CUTOFF" | while read -r file; do
        filename=$(basename "$file")
        local relative_path=${file#"$target_dir/"}
        timestamp_format=""

        # Padrão 1: Screenshot_20241231-091012
        datestring=$(echo "$filename" | sed -nE 's/.*_([0-9]{8})-([0-9]{6}).*/\1\2/p')
        if [ -n "$datestring" ]; then
            timestamp_format="${datestring:0:12}.${datestring:12:2}"
        
        # Padrão 4: IMG_20240920_180440_516
        elif datestring=$(echo "$filename" | sed -nE 's/.*_([0-9]{8})_([0-9]{6}).*/\1\2/p'); [ -n "$datestring" ]; then
            timestamp_format="${datestring:0:12}.${datestring:12:2}"

        # Padrão 5: 20241206_162351_HDR.jpg
        elif datestring=$(echo "$filename" | sed -nE 's/^(19[0-9]{6}|20[0-9]{6})_([0-9]{6}).*/\1\2/p'); [ -n "$datestring" ]; then
            timestamp_format="${datestring:0:12}.${datestring:12:2}"

        # Padrão 6: 2021-07-10-182324866.mp4
        elif datestring=$(echo "$filename" | sed -nE 's/.*([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6}).*/\1\2\3\4/p'); [ -n "$datestring" ]; then
            timestamp_format="${datestring:0:12}.${datestring:12:2}"
        
        # Padrão 2: VID-20241231-WA0153
        elif datestring=$(echo "$filename" | sed -nE 's/.*-([0-9]{8})-WA([0-9]{4}).*/\1\2/p'); [ -n "$datestring" ]; then
            datestring="${datestring}00" 
            timestamp_format="${datestring:0:12}.${datestring:12:2}"
        fi
        
        if [ -n "$timestamp_format" ]; then
            touch -m -t "$timestamp_format" "$file"
            if ! grep -qxF "$relative_path" "$log_success_file"; then
                echo "$relative_path" >> "$log_success_file"
            fi
        else
            if ! grep -qxF "$relative_path" "$log_failed_file"; then
                echo "$relative_path" >> "$log_failed_file"
            fi
        fi
    done
    echo "--- Plano B Concluído ---"
}

# ------------------------------------------------------------------------------
# Função de Verificação de Erro 509
# ------------------------------------------------------------------------------
check_for_509_error() {
    local log_file="$1"
    local operation_type="$2"
    
    sleep 2
    
    if grep -q "509 Bandwidth Limit Exceeded" "$log_file"; then
        TIME_LEFT=$(grep -h "X-Mega-Time-Left:" "$log_file" 2>/dev/null | tail -n 1 | grep -oE '[0-9]{2,6}' | head -n 1)
        [[ ! "$TIME_LEFT" =~ ^[0-9]+$ ]] && TIME_LEFT=3600
        
        WAIT_MINUTES=$(( (TIME_LEFT / 60) + 1 ))
        
        if [[ "$TIME_LEFT" -ge 3600 ]]; then
            HOURS=$((TIME_LEFT / 3600))
            MINUTES=$(((TIME_LEFT % 3600) / 60))
            TIME_DISPLAY="${HOURS}h ${MINUTES}min"
        else
            TIME_DISPLAY="${WAIT_MINUTES} minutos"
        fi
        
        echo
        echo "══════════════════════════════════════════════════════════════════"
        echo "  🚨 ERRO 509: LIMITE DE BANDA DO MEGA EXCEDIDO 🚨"
        echo "  Operação: ${operation_type}"
        echo "  ⏱️  Aguarde: ${TIME_DISPLAY}"
        echo "  💾 Arquivos: PRESERVADOS"
        echo "══════════════════════════════════════════════════════════════════"
        
        rm -f "$BATCH_FILE_LIST"
        exit 1
    else
        echo "ERRO: Falha no ${operation_type}."
        tail -n 5 "$log_file"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Função Principal de Processamento de Lote
# ------------------------------------------------------------------------------
process_batch() {
    local batch_list_file="$1"
    local log_success_file="$2"
    local log_failed_file="$3"
    
    echo "=================================================================="
    echo "LOTE PRONTO. Baixando $(wc -l < "$batch_list_file") arquivos..."
    echo "=================================================================="

    # Limpa log antigo
    > "$DOWNLOAD_LOG_FILE"
    
    # Executa rclone em BACKGROUND dentro de um pseudo-terminal
    script -q -c "rclone copy \"$REMOTE_PATH\" \"$BATCH_DIR\" \
           --files-from \"$batch_list_file\" \
           --ignore-existing \
           --progress \
           --stats-one-line \
           --stats 5s \
           --low-level-retries 2 \
           --retries 1 \
           --timeout 15s \
           --contimeout 5s \
           --expect-continue-timeout 5s \
           -vv" "$DOWNLOAD_LOG_FILE" &
           
    RCLONE_PID=$!
    
    # Monitora em tempo real com TIMEOUT DE 5 MINUTOS
    for i in {1..150}; do  # 150 * 2s = 300s = 5 minutos
        sleep 2
        
        # Verifica se processo ainda existe
        if ! kill -0 $RCLONE_PID 2>/dev/null; then
            break
        fi
        
        # Detecta erro 509
        if grep -q "509 Bandwidth Limit Exceeded" "$DOWNLOAD_LOG_FILE"; then
            echo
            echo "=== ERRO 509 DETECTADO! Finalizando download... ==="
            kill $RCLONE_PID 2>/dev/null
            wait $RCLONE_PID 2>/dev/null
            check_for_509_error "$DOWNLOAD_LOG_FILE" "Download"
        fi
    done
    
    # Se após 5 minutos ainda rodando, mata
    if kill -0 $RCLONE_PID 2>/dev/null; then
        echo "⚠️  Timeout de 5 minutos atingido. Finalizando..."
        kill $RCLONE_PID 2>/dev/null
        wait $RCLONE_PID 2>/dev/null
    fi
    
    # Verifica código de saída
    wait $RCLONE_PID
    RCLONE_EXIT_CODE=$?
    
    if [ $RCLONE_EXIT_CODE -ne 0 ]; then
        check_for_509_error "$DOWNLOAD_LOG_FILE" "Download"
    fi
    
    echo "Download do lote concluído."
    echo

    # --- PASSO A: Corrigir por EXIF ---
    echo "Iniciando Passo A: ExifTool..."
    exiftool "-DateTimeOriginal>FileModifyDate" -ext jpg -ext jpeg -ext png -ext mp4 -ext mov -r -m -P "$BATCH_DIR"
    echo "Passo A concluído."
    echo

    # --- PASSO A.2: Logar sucessos do ExifTool ---
    echo "Iniciando Passo A.2: Logando sucessos do ExifTool..."
    find "$BATCH_DIR" -type f ! -newermt "$SCRIPT_START_CUTOFF" | while read -r file; do
        local relative_path=${file#"$BATCH_DIR/"}
        if ! grep -qxF "$relative_path" "$log_success_file"; then
            echo "  [EXIF SUCESSO] $relative_path"
            echo "$relative_path" >> "$log_success_file"
        fi
    done

    # --- PASSO B: Corrigir por Nome ---
    echo "Iniciando Passo B: Correção por Nome..."
    run_plan_b_fix "$BATCH_DIR" "$log_success_file" "$log_failed_file"
    echo "Passo B concluído."
    echo

    # --- PASSO C: Upload ---
    echo "Iniciando Passo C: Enviando para o Mega..."
    
    > "$UPLOAD_LOG_FILE"
    
    rclone copy "$BATCH_DIR" "$REMOTE_PATH" \
           --files-from "$batch_list_file" \
           --progress \
           --low-level-retries 2 \
           --retries 1 \
           --timeout 15s \
           --contimeout 5s \
           --expect-continue-timeout 5s \
           -vv > "$UPLOAD_LOG_FILE" 2>&1 &
           
    RCLONE_PID=$!
    
    for i in {1..150}; do
        sleep 2
        if ! kill -0 $RCLONE_PID 2>/dev/null; then
            break
        fi
        if grep -q "509 Bandwidth Limit Exceeded" "$UPLOAD_LOG_FILE"; then
            echo "=== ERRO 509 DETECTADO! Finalizando upload..."
            kill $RCLONE_PID 2>/dev/null
            wait $RCLONE_PID 2>/dev/null
            check_for_509_error "$UPLOAD_LOG_FILE" "Upload"
        fi
    done
    
    if kill -0 $RCLONE_PID 2>/dev/null; then
        kill $RCLONE_PID 2>/dev/null
        wait $RCLONE_PID 2>/dev/null
    fi
    
    wait $RCLONE_PID
    if [ $? -ne 0 ]; then
        check_for_509_error "$UPLOAD_LOG_FILE" "Upload"
    fi
    
    echo "Upload concluído."
    echo

    # --- PASSO D: Limpar lote ---
    echo "Iniciando Passo D: Limpando lote local..."
    rm -rf "${BATCH_DIR:?}"/*
    rm -f "$batch_list_file"
    touch "$batch_list_file"
    echo "Lote local limpo."
    echo "=================================================================="
}

# ==============================================================================
# INÍCIO DO SCRIPT PRINCIPAL
# ==============================================================================

# Só gera a lista mestra se ela não existir
if [ ! -f "$MASTER_LIST_FILE" ]; then
    echo "Gerando lista de arquivos e tamanhos do Mega..."
    
    > "$LSJSON_LOG_FILE"
    
    rclone lsjson "$REMOTE_PATH" --files-only -R \
           --exclude-from "$LOG_SUCCESS" \
           --exclude-from "$LOG_FAILED" \
           --exclude-from "$LOG_IGNORE" \
           --low-level-retries 2 \
           --retries 1 \
           -vv > "$MASTER_LIST_FILE" 2> "$LSJSON_LOG_FILE" &
           
    RCLONE_PID=$!
    
    for i in {1..30}; do  # 30 * 2s = 60s timeout
        sleep 2
        if ! kill -0 $RCLONE_PID 2>/dev/null; then
            break
        fi
        if grep -q "509 Bandwidth Limit Exceeded" "$LSJSON_LOG_FILE"; then
            kill $RCLONE_PID 2>/dev/null
            wait $RCLONE_PID 2>/dev/null
            check_for_509_error "$LSJSON_LOG_FILE" "Listagem"
        fi
    done
    
    if kill -0 $RCLONE_PID 2>/dev/null; then
        kill $RCLONE_PID 2>/dev/null
        wait $RCLONE_PID 2>/dev/null
    fi
    
    wait $RCLONE_PID
    RCLONE_EXIT_CODE=$?
    
    if [ $RCLONE_EXIT_CODE -ne 0 ]; then
        check_for_509_error "$LSJSON_LOG_FILE" "Listagem"
    fi
    
    if [ ! -s "$MASTER_LIST_FILE" ]; then
        echo "ERRO: Lista mestra vazia. Verifique log: $LSJSON_LOG_FILE"
        exit 1
    fi
    
    echo "Lista gerada com sucesso."
else
    echo "Lista de arquivos mestra já existe, pulando geração."
fi

# Conta total de arquivos
total_files=$(jq '. | length' "$MASTER_LIST_FILE" 2>/dev/null || echo 0)

if [ "$total_files" -eq 0 ]; then
    echo "Nenhum arquivo novo para processar."
    rm -f "$MASTER_LIST_FILE" "$BATCH_FILE_LIST" "$DOWNLOAD_LOG_FILE" "$UPLOAD_LOG_FILE" "$LSJSON_LOG_FILE"
    exit 0
fi

echo "$total_files arquivos restantes. Iniciando lotes de $MAX_BATCH_SIZE_GB GB..."
echo

current_batch_size=0
total_seen=0

rm -f "$BATCH_FILE_LIST"
touch "$BATCH_FILE_LIST"

# Lê a lista e cria lotes
while IFS='|' read -r size path; do
    total_seen=$((total_seen + 1))
    if grep -qxF "$path" "$LOG_SUCCESS" 2>/dev/null; then
        echo "Arquivo $total_seen/$total_files: $path (PULADO - sucesso anterior)"
        continue
    fi
    if grep -qxF "$path" "$LOG_FAILED" 2>/dev/null; then
        echo "Arquivo $total_seen/$total_files: $path (PULADO - falhou anteriormente)"
        continue
    fi
    if grep -qxF "$path" "$LOG_IGNORE" 2>/dev/null; then
        echo "Arquivo $total_seen/$total_files: $path (PULADO - ignorado)"
        continue
    fi
    echo "$path" >> "$BATCH_FILE_LIST"
    [ "$size" == "null" ] && size=0
    current_batch_size=$((current_batch_size + size))
    
    echo "Arquivo $total_seen/$total_files: $path (Lote: $(($current_batch_size / 1024 / 1024)) MB)"
    
    if [ "$current_batch_size" -ge "$MAX_BATCH_SIZE_BYTES" ]; then
        process_batch "$BATCH_FILE_LIST" "$LOG_SUCCESS" "$LOG_FAILED"
        current_batch_size=0
    fi
    
done < <(jq -r '.[] | "\(.Size)|\(.Path)"' "$MASTER_LIST_FILE")

# Processa lote final
echo "Processando lote final..."
if [ -s "$BATCH_FILE_LIST" ]; then
    process_batch "$BATCH_FILE_LIST" "$LOG_SUCCESS" "$LOG_FAILED"
else
    echo "Nenhum arquivo restante."
fi

# Limpeza final
echo "Limpando arquivos temporários..."
rm -f "$MASTER_LIST_FILE" "$BATCH_FILE_LIST"
rm -rf "${BATCH_DIR:?}"
rm -f "$DOWNLOAD_LOG_FILE" "$UPLOAD_LOG_FILE" "$LSJSON_LOG_FILE"

echo "=================================================================="
echo "✅ TODOS OS LOTES FORAM PROCESSADOS. TAREFA CONCLUÍDA."
echo "Verifique '_log_failed_patterns.txt' para arquivos não corrigidos."
echo "Mova arquivos impossíveis para '_log_ignore.txt'."
echo "=================================================================="
