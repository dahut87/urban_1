<?php
declare(strict_types=1);

/**
 * UrbanHub - index.php
 * Dépôt attendu :
 * php/index.php
 * php/logo.webp
 *
 * Déploiement attendu :
 * /var/www/urbanhub/public/index.php
 * /var/www/urbanhub/.env
 */

ini_set('display_errors', '0');
error_reporting(E_ALL);

function esc(mixed $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES, 'UTF-8');
}

function loadEnv(string $path): array
{
    $config = [];

    if (!is_file($path)) {
        return $config;
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($lines === false) {
        return $config;
    }

    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#')) {
            continue;
        }

        $pos = strpos($line, '=');
        if ($pos === false) {
            continue;
        }

        $key = trim(substr($line, 0, $pos));
        $value = trim(substr($line, $pos + 1));
        $value = trim($value, "\"'");
        $config[$key] = $value;
    }

    return $config;
}

function badge(bool $ok, string $okText = 'OK', string $koText = 'KO'): string
{
    $label = $ok ? $okText : $koText;
    $class = $ok ? 'badge-ok' : 'badge-ko';
    return '<span class="badge ' . $class . '">' . esc($label) . '</span>';
}

function formatDate(?string $value): string
{
    if (!$value) {
        return '—';
    }

    try {
        $dt = new DateTime($value);
        return $dt->format('d/m/Y H:i');
    } catch (Throwable) {
        return $value;
    }
}

function formatDuration(mixed $minutes): string
{
    if ($minutes === null || $minutes === '') {
        return 'En cours';
    }

    $minutes = (int)$minutes;
    $hours = intdiv($minutes, 60);
    $mins = $minutes % 60;

    if ($hours > 0) {
        return sprintf('%dh%02d', $hours, $mins);
    }

    return sprintf('%d min', $mins);
}

$envPath = dirname(__DIR__) . '/.env';
$env = loadEnv($envPath);

$dbHost = $env['DB_HOST'] ?? '127.0.0.1';
$dbName = $env['DB_NAME'] ?? 'urbanhub';
$dbUser = $env['DB_USER'] ?? 'urbanhub_app';
$dbPass = $env['DB_PASSWORD'] ?? '';
$awsRegion = $env['AWS_REGION'] ?? 'eu-west-3';
$instanceHostname = $env['INSTANCE_HOSTNAME'] ?? gethostname() ?: php_uname('n');

$logoPath = __DIR__ . '/logo.webp';
$logoExists = is_file($logoPath);

$rdsCaPath = '/etc/ssl/rds/global-bundle.pem';
$rdsCaExists = is_file($rdsCaPath);

$dbOk = false;
$dbError = null;
$pdo = null;

$stats = [
    'parkings' => 0,
    'capacite_totale' => 0,
    'sessions_total' => 0,
    'sessions_actives' => 0,
];

$parkings = [];
$sessions = [];
$personsInParking = [];

try {
    $dsn = sprintf(
        'mysql:host=%s;dbname=%s;charset=utf8mb4',
        $dbHost,
        $dbName
    );

    $pdoOptions = [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ];

    if (defined('PDO::MYSQL_ATTR_SSL_CA') && $rdsCaExists) {
        $pdoOptions[PDO::MYSQL_ATTR_SSL_CA] = $rdsCaPath;
    }

    $pdo = new PDO($dsn, $dbUser, $dbPass, $pdoOptions);
    $dbOk = true;

    // Statistiques globales
    $statsStmt = $pdo->query("
        SELECT
            (SELECT COUNT(*) FROM parkings) AS parkings,
            (SELECT COALESCE(SUM(capacity),0) FROM parkings) AS capacite_totale,
            (SELECT COUNT(*) FROM parking_sessions) AS sessions_total,
            (SELECT COUNT(*) FROM parking_sessions WHERE status = 'active') AS sessions_actives
    ");
    $stats = $statsStmt->fetch() ?: $stats;

    // Vue parkings enrichie
    $parkingsStmt = $pdo->query("
        SELECT
            p.id,
            p.name,
            p.city,
            p.address,
            p.capacity,
            COUNT(ps.id) AS nb_sessions_total,
            SUM(CASE WHEN ps.status = 'active' THEN 1 ELSE 0 END) AS nb_actives,
            SUM(CASE WHEN ps.status = 'closed' THEN 1 ELSE 0 END) AS nb_cloturees,
            ROUND(COALESCE(AVG(ps.duration_minutes), 0), 0) AS duree_moyenne_minutes
        FROM parkings p
        LEFT JOIN parking_sessions ps ON ps.parking_id = p.id
        GROUP BY p.id, p.name, p.city, p.address, p.capacity
        ORDER BY p.name ASC
    ");
    $parkings = $parkingsStmt->fetchAll();

    // Sessions récentes
    $sessionsStmt = $pdo->query("
        SELECT
            immatriculation,
            parking,
            address,
            date_entree,
            date_sortie,
            duree_minutes,
            type_abonnement,
            montant,
            statut
        FROM v_parking_overview
        ORDER BY date_entree DESC
        LIMIT 25
    ");
    $sessions = $sessionsStmt->fetchAll();

    // Liste totale des personnes présentes dans les parkings
    $personsStmt = $pdo->query("
        SELECT
            v.owner_name AS personne,
            v.plate_number AS immatriculation,
            p.name AS parking,
            p.address,
            ps.entry_time AS date_entree,
            s.label AS type_abonnement
        FROM parking_sessions ps
        INNER JOIN vehicles v ON v.id = ps.vehicle_id
        INNER JOIN parkings p ON p.id = ps.parking_id
        LEFT JOIN subscriptions s ON s.id = v.subscription_id
        WHERE ps.status = 'active'
        ORDER BY p.name ASC, ps.entry_time DESC
    ");
    $personsInParking = $personsStmt->fetchAll();

} catch (Throwable $e) {
    $dbError = $e->getMessage();
}

$appOk = true;
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>UrbanHub - Tableau de bord</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        :root {
            --blue: #0b4f7a;
            --green: #48a23f;
            --red: #c62828;
            --amber: #b26a00;
            --bg: #f5f7fb;
            --card: #ffffff;
            --text: #1f2937;
            --muted: #202020;
            --border: #dbe2ea;
            --shadow: 0 8px 24px rgba(15, 23, 42, 0.08);
        }

        * { box-sizing: border-box; }

        body {
            margin: 0;
            font-family: Arial, Helvetica, sans-serif;
            background: var(--bg);
            color: var(--text);
        }

        .container {
            max-width: 1320px;
            margin: 32px auto;
            padding: 0 20px 40px;
        }

        .hero {
            background: linear-gradient(135deg, var(--blue), #14679b);
            color: #fff;
            border-radius: 18px;
            padding: 28px;
            box-shadow: var(--shadow);
            margin-bottom: 24px;
        }

        .hero-top {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 20px;
            flex-wrap: wrap;
        }

        .hero-title {
            display: flex;
            align-items: center;
            gap: 18px;
        }

        .hero-title img {
            width: 178px;
            height: 178px;
            object-fit: contain;
            background: rgba(255,255,255,0.8);
            border-radius: 16px;
            padding: 8px;
        }

        .hero h1 {
            margin: 0 0 8px;
            font-size: 2rem;
        }

        .hero p {
            margin: 0;
            max-width: 660px;
            line-height: 1.5;
            opacity: 0.96;
        }

        .instance-box {
            background: rgba(255,255,255,0.12);
            border: 1px solid rgba(255,255,255,0.18);
            border-radius: 14px;
            padding: 12px 16px;
            min-width: 260px;
        }

        .instance-box strong {
            display: block;
            font-size: 1rem;
            margin-bottom: 4px;
        }

        .meta {
            margin-top: 18px;
            display: flex;
            gap: 12px;
            flex-wrap: wrap;
        }

        .chip {
            background: rgba(255,255,255,0.12);
            border: 1px solid rgba(255,255,255,0.16);
            padding: 8px 12px;
            border-radius: 999px;
            font-size: 0.92rem;
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(12, 1fr);
            gap: 20px;
        }

        .card {
            background: var(--card);
            border: 1px solid var(--border);
            border-radius: 18px;
            box-shadow: var(--shadow);
            overflow: hidden;
        }

        .card-header {
            padding: 18px 20px;
            border-bottom: 1px solid var(--border);
            background: #f9fbfd;
        }

        .card-header h2, .card-header h3 {
            margin: 0;
        }

        .card-body {
            padding: 20px;
        }

        .span-12 { grid-column: span 12; }
        .span-6 { grid-column: span 6; }
        .span-4 { grid-column: span 4; }
        .span-3 { grid-column: span 3; }

        .status-list {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 12px;
        }

        .status-item, .kpi {
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 14px;
            background: #fff;
        }

        .status-item small,
        .kpi small {
            display: block;
            color: var(--muted);
            margin-bottom: 8px;
        }

        .status-item strong,
        .kpi strong {
            font-size: 1.05rem;
        }

        .badge {
            display: inline-block;
            padding: 6px 10px;
            border-radius: 999px;
            font-size: 0.88rem;
            font-weight: bold;
        }

        .badge-ok {
            background: #dcfce7;
            color: #166534;
        }

        .badge-ko {
            background: #fee2e2;
            color: #991b1b;
        }

        .kpi-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 12px;
        }

        .kpi strong {
            font-size: 1.35rem;
            color: var(--blue);
        }

        table {
            width: 100%;
            border-collapse: collapse;
            background: #fff;
        }

        thead {
            background: var(--blue);
            color: #fff;
        }

        th, td {
            text-align: left;
            padding: 12px 10px;
            border-bottom: 1px solid #e8edf3;
            vertical-align: top;
            font-size: 0.95rem;
        }

        tbody tr:hover {
            background: #f8fbff;
        }

        .muted {
            color: var(--muted);
        }

        .tag {
            display: inline-block;
            padding: 5px 9px;
            border-radius: 999px;
            font-size: 0.84rem;
            font-weight: bold;
            background: #eef2ff;
            color: #3730a3;
        }

        .tag.active {
            background: #fff7ed;
            color: #9a3412;
        }

        .tag.closed {
            background: #dcfce7;
            color: #166534;
        }

        .error-box {
            margin-top: 12px;
            padding: 12px 14px;
            border-radius: 12px;
            background: #fff1f2;
            color: #9f1239;
            border: 1px solid #fecdd3;
            font-family: monospace;
            font-size: 0.9rem;
            overflow-x: auto;
        }

        @media (max-width: 1100px) {
            .span-6, .span-4, .span-3 { grid-column: span 12; }
            .status-list, .kpi-grid { grid-template-columns: 1fr; }
        }
    </style>
</head>
<body>
    <div class="container">

        <section class="hero">
            <div class="hero-top">
                <div class="hero-title">
                    <?php if ($logoExists): ?>
                        <img src="logo.webp" alt="Logo UrbanHub">
                    <?php endif; ?>

                    <div>
                        <h1>UrbanHub</h1>
                        <p>
                            UrbanHub est une application de supervision du stationnement urbain.
                            Elle permet de centraliser l’état des parkings, de consulter les sessions
                            de stationnement, de suivre les capacités et de visualiser l’activité
                            applicative en environnement cloud.
                        </p>
                    </div>
                </div>

                <div class="instance-box">
                    <strong>Instance répondante</strong>
                    <div><?= esc($instanceHostname) ?></div>
                    <div class="muted">Région AWS : <?= esc($awsRegion) ?></div>
                </div>
            </div>

            <div class="meta">
                <div class="chip">Service : UrbanHub</div>
                <div class="chip">Base : <?= esc($dbName) ?></div>
                <div class="chip">Hôte BDD : <?= esc($dbHost) ?></div>
                <div class="chip">Frontend : Apache / PHP</div>
            </div>
        </section>

        <section class="grid">
            <div class="card span-6">
                <div class="card-header">
                    <h2>Présentation du service</h2>
                </div>
                <div class="card-body">
                    <p>
                        Cette interface présente un aperçu opérationnel de la plateforme UrbanHub.
                        Elle a vocation à démontrer le bon fonctionnement d’une application web
                        déployée sur AWS derrière un load balancer, avec une base de données distante.
                    </p>
                    <p>
                        Les tableaux ci-dessous reposent sur des requêtes SQL exécutées en direct
                        sur la base MariaDB afin d’afficher les parkings, les sessions actives,
                        l’historique récent et la santé globale des composants.
                    </p>
                </div>
            </div>

            <div class="card span-6">
                <div class="card-header">
                    <h2>Santé des services</h2>
                </div>
                <div class="card-body">
                    <div class="status-list">
                        <div class="status-item">
                            <small>Application PHP</small>
                            <strong><?= badge($appOk) ?></strong>
                        </div>
                        <div class="status-item">
                            <small>Connexion MariaDB</small>
                            <strong><?= badge($dbOk) ?></strong>
                        </div>
                        <div class="status-item">
                            <small>Présence du logo</small>
                            <strong><?= badge($logoExists) ?></strong>
                        </div>
                        <div class="status-item">
                            <small>Bundle CA RDS AWS</small>
                            <strong><?= badge($rdsCaExists) ?></strong>
                        </div>
                    </div>

                    <?php if (!$dbOk && $dbError !== null): ?>
                        <div class="error-box"><?= esc($dbError) ?></div>
                    <?php endif; ?>
                </div>
            </div>

            <div class="card span-12">
                <div class="card-header">
                    <h2>Indicateurs globaux</h2>
                </div>
                <div class="card-body">
                    <div class="kpi-grid">
                        <div class="kpi">
                            <small>Nombre de parkings</small>
                            <strong><?= esc($stats['parkings'] ?? 0) ?></strong>
                        </div>
                        <div class="kpi">
                            <small>Capacité totale</small>
                            <strong><?= esc($stats['capacite_totale'] ?? 0) ?></strong>
                        </div>
                        <div class="kpi">
                            <small>Sessions totales</small>
                            <strong><?= esc($stats['sessions_total'] ?? 0) ?></strong>
                        </div>
                        <div class="kpi">
                            <small>Sessions actives</small>
                            <strong><?= esc($stats['sessions_actives'] ?? 0) ?></strong>
                        </div>
                    </div>
                </div>
            </div>

            <div class="card span-12">
                <div class="card-header">
                    <h2>État des parkings</h2>
                    <h3 class="muted">Requête SQL : agrégation par parking</h3>
                </div>
                <div class="card-body" style="padding:0;">
                    <table>
                        <thead>
                            <tr>
                                <th>Parking</th>
                                <th>Ville</th>
                                <th>Adresse</th>
                                <th>Capacité</th>
                                <th>Sessions</th>
                                <th>Actives</th>
                                <th>Clôturées</th>
                                <th>Durée moyenne</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php if (count($parkings) === 0): ?>
                                <tr>
                                    <td colspan="8">Aucune donnée disponible.</td>
                                </tr>
                            <?php else: ?>
                                <?php foreach ($parkings as $row): ?>
                                    <tr>
                                        <td><strong><?= esc($row['name']) ?></strong></td>
                                        <td><?= esc($row['city']) ?></td>
                                        <td><?= esc($row['address']) ?></td>
                                        <td><?= esc($row['capacity']) ?></td>
                                        <td><?= esc($row['nb_sessions_total']) ?></td>
                                        <td><?= esc($row['nb_actives']) ?></td>
                                        <td><?= esc($row['nb_cloturees']) ?></td>
                                        <td><?= esc(formatDuration($row['duree_moyenne_minutes'])) ?></td>
                                    </tr>
                                <?php endforeach; ?>
                            <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>

            <div class="card span-12">
                <div class="card-header">
                    <h2>Personnes actuellement présentes dans les parkings</h2>
                    <h3 class="muted">Requête SQL : véhicules avec session active</h3>
                </div>
                <div class="card-body" style="padding:0;">
                    <table>
                        <thead>
                            <tr>
                                <th>Personne</th>
                                <th>Immatriculation</th>
                                <th>Parking</th>
                                <th>Adresse</th>
                                <th>Entrée</th>
                                <th>Abonnement</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php if (count($personsInParking) === 0): ?>
                                <tr>
                                    <td colspan="6">Aucune personne actuellement présente.</td>
                                </tr>
                            <?php else: ?>
                                <?php foreach ($personsInParking as $row): ?>
                                    <tr>
                                        <td><strong><?= esc($row['personne']) ?></strong></td>
                                        <td><?= esc($row['immatriculation']) ?></td>
                                        <td><?= esc($row['parking']) ?></td>
                                        <td><?= esc($row['address']) ?></td>
                                        <td><?= esc(formatDate($row['date_entree'])) ?></td>
                                        <td><?= esc($row['type_abonnement']) ?></td>
                                    </tr>
                                <?php endforeach; ?>
                            <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>

            <div class="card span-12">
                <div class="card-header">
                    <h2>Sessions récentes</h2>
                    <h3 class="muted">Requête SQL : vue applicative v_parking_overview</h3>
                </div>
                <div class="card-body" style="padding:0;">
                    <table>
                        <thead>
                            <tr>
                                <th>Immatriculation</th>
                                <th>Parking</th>
                                <th>Adresse</th>
                                <th>Entrée</th>
                                <th>Sortie</th>
                                <th>Durée</th>
                                <th>Abonnement</th>
                                <th>Montant</th>
                                <th>Statut</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php if (count($sessions) === 0): ?>
                                <tr>
                                    <td colspan="9">Aucune session disponible.</td>
                                </tr>
                            <?php else: ?>
                                <?php foreach ($sessions as $row): ?>
                                    <tr>
                                        <td><strong><?= esc($row['immatriculation']) ?></strong></td>
                                        <td><?= esc($row['parking']) ?></td>
                                        <td><?= esc($row['address']) ?></td>
                                        <td><?= esc(formatDate($row['date_entree'])) ?></td>
                                        <td><?= esc(formatDate($row['date_sortie'])) ?></td>
                                        <td><?= esc(formatDuration($row['duree_minutes'])) ?></td>
                                        <td><?= esc($row['type_abonnement']) ?></td>
                                        <td>
                                            <?= $row['montant'] !== null ? esc(number_format((float)$row['montant'], 2, ',', ' ')) . ' €' : '—' ?>
                                        </td>
                                        <td>
                                            <span class="tag <?= esc((string)$row['statut']) ?>">
                                                <?= esc($row['statut']) ?>
                                            </span>
                                        </td>
                                    </tr>
                                <?php endforeach; ?>
                            <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>
        </section>
    </div>
</body>
</html>