CREATE DATABASE IF NOT EXISTS urbanhub
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE urbanhub;

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
  DECLARE plate_a CHAR(1);
  DECLARE plate_b CHAR(1);
  DECLARE plate_c CHAR(1);
  DECLARE plate_d CHAR(1);
  DECLARE owner_label VARCHAR(100);

  DECLARE total_vehicles INT DEFAULT 4550;

  DECLARE active_target_rep INT DEFAULT 152;
  DECLARE active_target_gare INT DEFAULT 148;
  DECLARE active_target_hdv INT DEFAULT 96;
  DECLARE active_target_dussoubs INT DEFAULT 54;
  DECLARE active_target_champ INT DEFAULT 38;

  DECLARE active_total INT DEFAULT 488;
  DECLARE parking_id_local INT;
  DECLARE hist_parking_id INT;
  DECLARE entry_dt DATETIME;
  DECLARE dur INT;
  DECLARE sub_local INT;

  /* =========================
     Création des véhicules
     ========================= */
  WHILE i <= total_vehicles DO
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

    SET owner_label = CONCAT('Usager Limoges ', LPAD(i, 4, '0'));

    INSERT INTO vehicles (plate_number, owner_name, subscription_id)
    VALUES (
      CONCAT(plate_a, plate_b, '-', LPAD(MOD(i * 17, 1000), 3, '0'), '-', plate_c, plate_d),
      owner_label,
      sub_id
    );

    SET i = i + 1;
  END WHILE;

  /* =========================
     Sessions ACTIVES
     Répartition inégale, sans dépasser la capacité
     ========================= */

  /* Parking République (id=1) : 152 actives / 200 */
  SET i = 1;
  WHILE i <= active_target_rep DO
    INSERT INTO parking_sessions (
      vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
    )
    VALUES (
      i,
      1,
      TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL MOD(i, 3) DAY), MAKETIME(7 + MOD(i, 10), MOD(i * 7, 60), 0)),
      NULL,
      NULL,
      NULL,
      'active'
    );
    SET i = i + 1;
  END WHILE;

  /* Parking Gare Bénédictins (id=2) : 148 actives / 300 */
  SET i = active_target_rep + 1;
  WHILE i <= active_target_rep + active_target_gare DO
    INSERT INTO parking_sessions (
      vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
    )
    VALUES (
      i,
      2,
      TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL MOD(i, 4) DAY), MAKETIME(6 + MOD(i, 12), MOD(i * 5, 60), 0)),
      NULL,
      NULL,
      NULL,
      'active'
    );
    SET i = i + 1;
  END WHILE;

  /* Parking Hôtel de Ville (id=3) : 96 actives / 150 */
  SET i = active_target_rep + active_target_gare + 1;
  WHILE i <= active_target_rep + active_target_gare + active_target_hdv DO
    INSERT INTO parking_sessions (
      vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
    )
    VALUES (
      i,
      3,
      TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL MOD(i, 2) DAY), MAKETIME(8 + MOD(i, 9), MOD(i * 3, 60), 0)),
      NULL,
      NULL,
      NULL,
      'active'
    );
    SET i = i + 1;
  END WHILE;

  /* Parking Denis Dussoubs (id=4) : 54 actives / 120 */
  SET i = active_target_rep + active_target_gare + active_target_hdv + 1;
  WHILE i <= active_target_rep + active_target_gare + active_target_hdv + active_target_dussoubs DO
    INSERT INTO parking_sessions (
      vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
    )
    VALUES (
      i,
      4,
      TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL MOD(i, 5) DAY), MAKETIME(9 + MOD(i, 8), MOD(i * 11, 60), 0)),
      NULL,
      NULL,
      NULL,
      'active'
    );
    SET i = i + 1;
  END WHILE;

  /* Parking Champ de Juillet (id=5) : 38 actives / 250 */
  SET i = active_target_rep + active_target_gare + active_target_hdv + active_target_dussoubs + 1;
  WHILE i <= active_total DO
    INSERT INTO parking_sessions (
      vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
    )
    VALUES (
      i,
      5,
      TIMESTAMP(DATE_SUB('2026-03-30', INTERVAL MOD(i, 6) DAY), MAKETIME(7 + MOD(i, 11), MOD(i * 13, 60), 0)),
      NULL,
      NULL,
      NULL,
      'active'
    );
    SET i = i + 1;
  END WHILE;

  /* =========================
     Historique CLOTURÉ
     Le reste des véhicules
     Répartition inégale mais réaliste
     ========================= */
  SET i = active_total + 1;
  WHILE i <= total_vehicles DO
    SET hist_parking_id =
      CASE
        WHEN MOD(i, 10) IN (0,1,2) THEN 2
        WHEN MOD(i, 10) IN (3,4) THEN 1
        WHEN MOD(i, 10) IN (5,6) THEN 5
        WHEN MOD(i, 10) = 7 THEN 3
        ELSE 4
      END;

    SET dur = 20 + MOD(i * 23, 600);
    SET sub_local = (
      SELECT subscription_id FROM vehicles WHERE id = i
    );

    SET entry_dt = TIMESTAMP(
      DATE_SUB('2026-03-30', INTERVAL MOD(i, 30) DAY),
      MAKETIME(6 + MOD(i * 3, 12), MOD(i * 7, 60), 0)
    );

    INSERT INTO parking_sessions (
      vehicle_id, parking_id, entry_time, exit_time, duration_minutes, amount_due, status
    )
    VALUES (
      i,
      hist_parking_id,
      entry_dt,
      TIMESTAMPADD(MINUTE, dur, entry_dt),
      dur,
      CASE
        WHEN sub_local IN (2,3) THEN 0.00
        WHEN sub_local = 4 THEN ROUND(dur * 0.03, 2)
        ELSE ROUND(dur * 0.05, 2)
      END,
      'closed'
    );

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