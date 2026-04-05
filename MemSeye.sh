#!/bin/bash

# ============================================
# 内存马全面检测工具
# 支持: Filter, Servlet, Valve, Listener, Controller
# 使用方法: ./memshell_killer.sh <PID> [ARTHAS_PATH]
# 示例: ./memshell_killer.sh 23288
# ============================================

PID=$1
ARTHAS_PATH=${2:-"./arthas-boot.jar"}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TEMP_DIR="/tmp/memshell_$$"
mkdir -p "$TEMP_DIR"
SUSPECT_SUMMARY="$TEMP_DIR/suspect_summary.txt"

cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null
}
trap cleanup EXIT

if [ -z "$PID" ]; then
    echo -e "${RED}错误: 请指定Java进程PID${NC}"
    echo "使用方法: ./memshell_killer.sh <PID>"
    echo "示例: ./memshell_killer.sh 23288"
    exit 1
fi

if [ ! -f "$ARTHAS_PATH" ]; then
    echo -e "${RED}错误: 找不到 $ARTHAS_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}内存马全面检测工具${NC}"
echo -e "${GREEN}目标进程: $PID${NC}"
echo -e "${GREEN}========================================${NC}"

# ============================================
# 清理旧的 Arthas 会话
# ============================================
echo -e "${YELLOW}[0/5] 清理旧 Arthas 会话...${NC}"

# 尝试发送 stop 命令
echo "stop" | java -jar "$ARTHAS_PATH" --target-ip 127.0.0.1 --telnet-port 3658 2>/dev/null
echo "stop" | java -jar "$ARTHAS_PATH" --target-ip 127.0.0.1 --telnet-port 8563 2>/dev/null

# 杀掉可能的 arthas 客户端进程
ps -ef 2>/dev/null | grep -E "arthas-client|as.sh" | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null

sleep 1
echo -e "${GREEN}清理完成${NC}"
echo ""

# ============================================
# 检测函数（单类型）
# ============================================
check_type() {
    local type=$1
    local cmd=$2
    local class_file="$TEMP_DIR/${type}_classes.txt"
    local suspect_file="$TEMP_DIR/${type}_suspect.txt"
    
    echo -e "${BLUE}[检测] $type 内存马${NC}"
    
    # 执行命令获取类列表
    java -jar "$ARTHAS_PATH" "$PID" -c "$cmd" 2>/dev/null | \
        grep -E "^[a-z][a-z0-9.]*\.([A-Z][a-zA-Z0-9]*\.?)*" > "$class_file"
    
    # 过滤掉接口/父类本身
    local parent=$(echo "$cmd" | awk '{print $NF}')
    grep -v "^$parent$" "$class_file" 2>/dev/null | sort -u > "${class_file}.clean"
    
    local total=$(wc -l < "${class_file}.clean" 2>/dev/null | tr -d ' ')
    echo -e "  找到 ${total:-0} 个类"
    
    if [ "${total:-0}" -eq 0 ]; then
        echo -e "  ${GREEN}无${NC}\n"
        return
    fi
    
    # 逐个检查 code-source
    > "$suspect_file"
    local suspect_count=0
    
    while IFS= read -r classname; do
        [ -z "$classname" ] && continue
        
        # 获取 sc -d 输出，提取 code-source 的值
        # 格式: "code-source       /F:/tomcat/xxx.jar" 或 "code-source       "
        cs_value=$(java -jar "$ARTHAS_PATH" "$PID" -c "sc -d $classname" 2>/dev/null | \
            grep "code-source" | head -1 | \
            sed 's/.*code-source//' | \
            sed 's/^[[:space:]]*//')
        
        # 判断：code-source 值为空 → 可疑内存马
        if [ -z "$cs_value" ]; then
            echo "$classname" >> "$suspect_file"
            ((suspect_count++))
        fi
    done < "${class_file}.clean"
    
    if [ "$suspect_count" -gt 0 ]; then
        echo -e "  ${RED}[!] 发现 ${suspect_count} 个可疑类${NC}"
        cat "$suspect_file" | head -10 | while read c; do
            echo -e "      - $c"
        done
        [ "$suspect_count" -gt 10 ] && echo -e "      ... 还有 $((suspect_count - 10)) 个"
        echo "=== $type ===" >> "$SUSPECT_SUMMARY"
        cat "$suspect_file" >> "$SUSPECT_SUMMARY"
        echo "" >> "$SUSPECT_SUMMARY"
    else
        echo -e "  ${GREEN}[✓] 未发现可疑类${NC}"
    fi
    
    echo ""
}

# ============================================
# 执行检测
# ============================================
> "$SUSPECT_SUMMARY"

# 1. Filter (实现接口)
check_type "Filter" "sc javax.servlet.Filter"

# 2. Servlet (实现接口)
check_type "Servlet" "sc javax.servlet.Servlet"

# 3. Valve (继承 ValveBase，使用 -s)
check_type "Valve" "sc -s org.apache.catalina.valves.ValveBase"

# 4. Listener (实现接口)
check_type "Listener" "sc javax.servlet.ServletContextListener"

# 5. Controller (注解)
echo -e "${BLUE}[检测] Controller 内存马${NC}"
CONTROLLER_FILE="$TEMP_DIR/controller_classes.txt"
> "$CONTROLLER_FILE"

# 搜索 @Controller 和 @RestController
java -jar "$ARTHAS_PATH" "$PID" -c "sc *@Controller" 2>/dev/null | \
    grep -E "^[a-z][a-z0-9.]*\.([A-Z][a-zA-Z0-9]*\.?)*" >> "$CONTROLLER_FILE"

java -jar "$ARTHAS_PATH" "$PID" -c "sc *@RestController" 2>/dev/null | \
    grep -E "^[a-z][a-z0-9.]*\.([A-Z][a-zA-Z0-9]*\.?)*" >> "$CONTROLLER_FILE"

sort -u "$CONTROLLER_FILE" -o "$CONTROLLER_FILE" 2>/dev/null
CONTROLLER_COUNT=$(wc -l < "$CONTROLLER_FILE" 2>/dev/null | tr -d ' ')
echo -e "  找到 ${CONTROLLER_COUNT:-0} 个 Controller 类"

> "$TEMP_DIR/controller_suspect.txt"
SUSPECT_CONTROLLER=0

while IFS= read -r classname; do
    [ -z "$classname" ] && continue
    
    cs_value=$(java -jar "$ARTHAS_PATH" "$PID" -c "sc -d $classname" 2>/dev/null | \
        grep "code-source" | head -1 | \
        sed 's/.*code-source//' | \
        sed 's/^[[:space:]]*//')
    
    if [ -z "$cs_value" ]; then
        echo "$classname" >> "$TEMP_DIR/controller_suspect.txt"
        ((SUSPECT_CONTROLLER++))
    fi
done < "$CONTROLLER_FILE"

if [ "$SUSPECT_CONTROLLER" -gt 0 ]; then
    echo -e "  ${RED}[!] 发现 ${SUSPECT_CONTROLLER} 个可疑 Controller${NC}"
    cat "$TEMP_DIR/controller_suspect.txt" | head -10 | while read c; do
        echo -e "      - $c"
    done
    echo "=== Controller ===" >> "$SUSPECT_SUMMARY"
    cat "$TEMP_DIR/controller_suspect.txt" >> "$SUSPECT_SUMMARY"
    echo "" >> "$SUSPECT_SUMMARY"
else
    echo -e "  ${GREEN}[✓] 未发现可疑 Controller${NC}"
fi

echo ""

# ============================================
# 输出汇总结果
# ============================================
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}检测结果汇总${NC}"
echo -e "${GREEN}========================================${NC}"

if [ -s "$SUSPECT_SUMMARY" ]; then
    echo -e "${RED}发现可疑内存马 (code-source 为空):${NC}"
    echo ""
    cat "$SUSPECT_SUMMARY"
else
    echo -e "${GREEN}✓ 未检测到 code-source 异常的内存马${NC}"
fi

# ============================================
# 清理建议
# ============================================
echo ""
echo -e "${YELLOW}清理建议${NC}"
echo -e "${GREEN}========================================${NC}"

if [ -s "$SUSPECT_SUMMARY" ]; then
    echo -e "${RED}1. 重启 Tomcat 是最彻底的清理方式${NC}"
    echo ""
    echo "2. 手动连接 Arthas 分析:"
    echo "   java -jar $ARTHAS_PATH $PID"
    echo ""
    echo "3. 可疑类反编译命令:"
    while IFS= read -r line; do
        if [[ "$line" == ===* ]]; then
            echo ""
            echo -e "   ${YELLOW}${line}${NC}"
        elif [ -n "$line" ] && [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
            echo "      jad $line"
        fi
    done < "$SUSPECT_SUMMARY"
    echo ""
    echo -e "${YELLOW}4. 检查并清理 webapps 目录下的后门 JSP 文件${NC}"
    echo -e "${YELLOW}5. 检查启动参数: jps -lv | grep javaagent${NC}"
else
    echo -e "${GREEN}✓ 未检测到内存马${NC}"
fi

echo ""
echo -e "${GREEN}检测完成${NC}"
