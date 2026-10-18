#!/usr/bin/env node
const { execSync } = require('child_process');

try {
  execSync('bash start.sh', { stdio: 'inherit' });
} catch (error) {
  console.error("\n[Node.js] 启动脚本执行异常退出！请检查上方日志。");
  process.exit(0); 
}
