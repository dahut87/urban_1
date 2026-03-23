CREATE DATABASE IF NOT EXISTS urbanhub
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE urbanhub;

SET NAMES utf8mb4;

DROP VIEW IF EXISTS v_parking_overview;

DROP TABLE IF EXISTS parking_sessions;
DROP TABLE IF EXISTS vehicles;
DROP TABLE IF EXISTS subscriptions;
DROP TABLE IF EXISTS parkings;

CREATE TABLE parkings (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  city VARCHAR(100) NOT NULL DEFAULT 'Limoges',
  address VARCHAR(255) NOT NULL,
  capacity INT NOT NULL DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE subscriptions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(30) NOT NULL UNIQUE,
  label VARCHAR(100) NOT NULL,
  description VARCHAR(255) DEFAULT NULL,
  monthly_price DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE vehicles (
  id INT AUTO_INCREMENT PRIMARY KEY,
  plate_number VARCHAR(20) NOT NULL UNIQUE,
  owner_name VARCHAR(100) DEFAULT NULL,
  subscription_id INT DEFAULT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_vehicle_subscription
    FOREIGN KEY (subscription_id) REFERENCES subscriptions(id)
    ON DELETE SET NULL
    ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE parking_sessions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  vehicle_id INT NOT NULL,
  parking_id INT NOT NULL,
  entry_time DATETIME NOT NULL,
  exit_time DATETIME DEFAULT NULL,
  duration_minutes INT DEFAULT NULL,
  amount_due DECIMAL(10,2) DEFAULT NULL,
  status ENUM('active', 'closed') NOT NULL DEFAULT 'active',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_session_vehicle
    FOREIGN KEY (vehicle_id) REFERENCES vehicles(id)
    ON DELETE CASCADE,
  CONSTRAINT fk_session_parking
    FOREIGN KEY (parking_id) REFERENCES parkings(id)
    ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE INDEX idx_sessions_vehicle_id ON parking_sessions(vehicle_id);
CREATE INDEX idx_sessions_parking_id ON parking_sessions(parking_id);
CREATE INDEX idx_sessions_entry_time ON parking_sessions(entry_time);
CREATE INDEX idx_sessions_status ON parking_sessions(status);

INSERT INTO subscriptions (code, label, description, monthly_price) VALUES
('AUCUN', 'Aucun abonnement', 'Stationnement ponctuel', 0.00),
('RESIDENT', 'Résident Limoges', 'Abonnement résident centre-ville', 15.00),
('PRO', 'Professionnel', 'Abonnement entreprise Limoges', 45.00),
('VISITEUR', 'Visiteur', 'Accès temporaire', 0.00);

INSERT INTO parkings (name, city, address, capacity) VALUES
('Parking République', 'Limoges', 'Place de la République', 200),
('Parking Gare Bénédictins', 'Limoges', '4 Place Maison Dieu', 300),
('Parking Hôtel de Ville', 'Limoges', 'Rue Jean Jaurès', 150),
('Parking Denis Dussoubs', 'Limoges', 'Boulevard Louis Blanc', 120),
('Parking Champ de Juillet', 'Limoges', 'Avenue du Champ de Juillet', 250);

DELIMITER $$

CREATE PROCEDURE seed_urbanhub()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE sub_id INT;
  DECLARE park_id INT;
  DECLARE hh INT;
  DECLARE mm INT;
  DECLARE dur INT;
  DECLARE day_offset INT;
  DECLARE plate_a CHAR(1);
  DECLARE plate_b CHAR(1);
  DECLARE plate_c CHAR(1);
  DECLARE plate_d CHAR(1);
  DECLARE owner_label VARCHAR(100);

  WHILE i <= 150 DO

    SET sub_id =
      CASE
        WHEN MOD(i, 10) IN (1,2,3,4) THEN 1
        WHEN MOD(i, 10) IN (5,6,7) THEN 2
        WHEN MOD(i, 10) IN (8,9) THEN 3
        ELSE 4
      END;

    SET plate_a = CHAR(65 + MOD(i, 26));
    SET plate_b = CHAR(65 + MOD(i + 7, 26));
    SET plate_c = CHAR(65 + MOD(i + 13, 26));
    SET plate_d = CHAR(65 + MOD(i + 19, 26));

    SET owner_label = CONCAT('Usager Limoges ', LPAD(i, 3, '0'));

    INSERT INTO vehicles (plate_number, owner_name, subscription_id)
    VALUES (
      CONCAT(plate_a, plate_b, '-', LPAD(MOD(i * 17, 1000), 3, '0'), '-', plate_c, plate_d),
      owner_label,
      sub_id
    );

    SET park_id = 1 + MOD(i - 1, 5);
    SET day_offset = MOD(i - 1, 30);
    SET hh = 7 + MOD(i * 3, 11);
    SET mm = MOD(i * 7, 60);
    SET dur = 20 + MOD(i * 23, 600);

    IF MOD(i, 6) = 0 THEN
      INSERT INTO parking_sessions (
        vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
      )
      VALUES (
        i,
        park_id,
        TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL day_offset DAY), MAKETIME(hh, mm, 0)),
        NULL,
        NULL,
        NULL,
        'active'
      );
    ELSE
      INSERT INTO parking_sessions (
        vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
      )
      VALUES (
        i,
        park_id,
        TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL day_offset DAY), MAKETIME(hh, mm, 0)),
        TIMESTAMPADD(
          MINUTE,
          dur,
          TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL day_offset DAY), MAKETIME(hh, mm, 0))
        ),
        dur,
        CASE
          WHEN sub_id IN (2,3) THEN 0.00
          WHEN sub_id = 4 THEN ROUND(dur * 0.03, 2)
          ELSE ROUND(dur * 0.05, 2)
        END,
        'closed'
      );
    END IF;

    SET i = i + 1;
  END WHILE;
END$$

DELIMITER ;

CALL seed_urbanhub();
DROP PROCEDURE seed_urbanhub;

CREATE OR REPLACE VIEW v_parking_overview AS
SELECT
  ps.id,
  v.plate_number AS immatriculation,
  p.name AS parking,
  p.address,
  ps.entry_time AS date_entree,
  ps.exit_time AS date_sortie,
  ps.duration_minutes AS duree_minutes,
  s.label AS type_abonnement,
  ps.amount_due AS montant,
  ps.status AS statut
FROM parking_sessions ps
JOIN vehicles v ON v.id = ps.vehicle_id
JOIN parkings p ON p.id = ps.parking_id
LEFT JOIN subscriptions s ON s.id = v.subscription_id
ORDER BY ps.entry_time DESC;