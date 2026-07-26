CREATE TABLE orders2 (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    total_cents INT NOT NULL DEFAULT 0,
    CONSTRAINT fk_orders_user_2 FOREIGN KEY (user_id) REFERENCES users (id)
);
