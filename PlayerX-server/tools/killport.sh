lsof -ti :2026 | xargs kill
lsof -ti :2026
nodemon ../server.js