const express = require("express");
const fs = require("fs");
const path = require("path");
const app = express();
const PORT = 3000;

app.use(express.json());
app.use(express.static("public")); // serves form site if you want

const filePath = path.join(__dirname, "feedback.json");

// Submit feedback
app.post("/api/feedback", (req, res) => {
  const { name, feedback } = req.body;
  if (!name || !feedback) {
    return res.status(400).json({ message: "Name and feedback are required." });
  }

  const feedbackData = {
    name,
    feedback,
    date: new Date().toISOString()
  };

  let feedbacks = [];
  if (fs.existsSync(filePath)) {
    feedbacks = JSON.parse(fs.readFileSync(filePath, "utf8") || "[]");
  }
  feedbacks.push(feedbackData);

  fs.writeFileSync(filePath, JSON.stringify(feedbacks, null, 2));
  res.json({ message: "Thank you for your feedback!" });
});

// 🔹 New endpoint: Get all feedback
app.get("/api/feedback", (req, res) => {
  if (!fs.existsSync(filePath)) {
    return res.json([]);
  }
  const feedbacks = JSON.parse(fs.readFileSync(filePath, "utf8") || "[]");
  res.json(feedbacks);
});

app.listen(PORT, () => {
  console.log(`Server running at http://localhost:${PORT}`);
});
