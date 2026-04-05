# MemSeye
基于alibaba arthas.jar的自动化java内存马扫描脚本 支持filter servlet listener valve controller类型内存马的检测 并给出清除建议

usage: ./MemSeye.sh <java-pid>
你可以使用 jps -l 来查看所有java进程pid来attatch

**运行效果** (以哥斯拉注入的filter和servlet内存马为例)
<img width="582" height="473" alt="image" src="https://github.com/user-attachments/assets/24eb6cd3-8de5-4951-a7c4-6c401cad71be" />

