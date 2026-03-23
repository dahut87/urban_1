<?php
declare(strict_types=1);

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

function getPositiveInt(string $key, int $default = 1): int
{
    $value = filter_input(INPUT_GET, $key, FILTER_VALIDATE_INT);
    if ($value === false || $value === null || $value < 1) {
        return $default;
    }
    return $value;
}

$envPath = dirname(__DIR__) . '/.env';
$env = loadEnv($envPath);

$dbHost = $env['DB_HOST'] ?? '127.0.0.1';
$dbName = $env['DB_NAME'] ?? 'urbanhub';
$dbUser = $env['DB_USER'] ?? 'urbanhub_app';
$dbPass = $env['DB_PASSWORD'] ?? '';
$awsRegion = $env['AWS_REGION'] ?? 'eu-west-3';
$awsAccountId = $env['AWS_ACCOUNT_ID'] ?? 'inconnu';
$awsRdsInstanceId = $env['AWS_RDS_INSTANCE_ID'] ?? 'inconnu';
$instanceHostname = $env['INSTANCE_HOSTNAME'] ?? gethostname() ?: php_uname('n');

$logoPath = __DIR__ . '/logo.webp';
$logoExists = is_file($logoPath);

$rdsCaPath = '/etc/ssl/rds/global-bundle.pem';
$rdsCaExists = is_file($rdsCaPath);

$dbOk = false;
$dbError = null;

$stats = [
    'parkings' => 0,
    'capacite_totale' => 0,
    'sessions_total' => 0,
    'sessions_actives' => 0,
];

$parkings = [];
$sessions = [];
$personsInParking = [];

$chartLabels = [];
$chartCapacity = [];
$chartActive = [];
$chartFree = [];

$personsPage = getPositiveInt('persons_page', 1);
$sessionsPage = getPositiveInt('sessions_page', 1);

$personsPerPage = 10;
$sessionsPerPage = 10;

$totalPersons = 0;
$totalPersonsPages = 1;
$totalSessions = 0;
$totalSessionsPages = 1;

try {
    $dsn = sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $dbHost, $dbName);

    $pdoOptions = [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ];

    if (defined('PDO::MYSQL_ATTR_SSL_CA') && $rdsCaExists) {
        $pdoOptions[PDO::MYSQL_ATTR_SSL_CA] = $rdsCaPath;
    }

    $pdo = new PDO($dsn, $dbUser, $dbPass, $pdoOptions);
    $dbOk = true;

    $statsStmt = $pdo->query("
        SELECT
            (SELECT COUNT(*) FROM parkings) AS parkings,
            (SELECT COALESCE(SUM(capacity),0) FROM parkings) AS capacite_totale,
            (SELECT COUNT(*) FROM parking_sessions) AS sessions_total,
            (SELECT COUNT(*) FROM parking_sessions WHERE status = 'active') AS sessions_actives
    ");
    $stats = $statsStmt->fetch() ?: $stats;

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

    foreach ($parkings as $row) {
        $capacity = (int)$row['capacity'];
        $active = (int)$row['nb_actives'];
        $free = max(0, $capacity - $active);

        $chartLabels[] = $row['name'];
        $chartCapacity[] = $capacity;
        $chartActive[] = $active;
        $chartFree[] = $free;
    }

    $countPersonsStmt = $pdo->query("
        SELECT COUNT(*)
        FROM parking_sessions ps
        INNER JOIN vehicles v ON v.id = ps.vehicle_id
        INNER JOIN parkings p ON p.id = ps.parking_id
        LEFT JOIN subscriptions s ON s.id = v.subscription_id
        WHERE ps.status = 'active'
    ");
    $totalPersons = (int)$countPersonsStmt->fetchColumn();
    $totalPersonsPages = max(1, (int)ceil($totalPersons / $personsPerPage));
    $personsPage = min($personsPage, $totalPersonsPages);
    $personsOffset = ($personsPage - 1) * $personsPerPage;

    $personsStmt = $pdo->prepare("
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
        LIMIT :limit OFFSET :offset
    ");
    $personsStmt->bindValue(':limit', $personsPerPage, PDO::PARAM_INT);
    $personsStmt->bindValue(':offset', $personsOffset, PDO::PARAM_INT);
    $personsStmt->execute();
    $personsInParking = $personsStmt->fetchAll();

    $countSessionsStmt = $pdo->query("SELECT COUNT(*) FROM v_parking_overview");
    $totalSessions = (int)$countSessionsStmt->fetchColumn();
    $totalSessionsPages = max(1, (int)ceil($totalSessions / $sessionsPerPage));
    $sessionsPage = min($sessionsPage, $totalSessionsPages);
    $sessionsOffset = ($sessionsPage - 1) * $sessionsPerPage;

    $sessionsStmt = $pdo->prepare("
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
        LIMIT :limit OFFSET :offset
    ");
    $sessionsStmt->bindValue(':limit', $sessionsPerPage, PDO::PARAM_INT);
    $sessionsStmt->bindValue(':offset', $sessionsOffset, PDO::PARAM_INT);
    $sessionsStmt->execute();
    $sessions = $sessionsStmt->fetchAll();

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
    <link rel="stylesheet" href="affichage.css">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
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
                <div class="chip">Compte AWS : <?= esc($awsAccountId) ?></div>
                <div class="chip">Instance RDS : <?= esc($awsRdsInstanceId) ?></div>
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
                        Les tableaux et graphiques ci-dessous reposent sur des requêtes SQL exécutées
                        en direct sur la base MariaDB afin d’afficher les parkings, les sessions actives,
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
                    <h2>Occupation des parkings</h2>
                    <h3 class="muted">Graphique : capacité, occupation active et places restantes</h3>
                </div>
                <div class="card-body">
                    <canvas id="parkingChart" height="110"></canvas>
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
                                <tr><td colspan="8">Aucune donnée disponible.</td></tr>
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

            <div class="card span-12" id="persons-section">
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
                                <tr><td colspan="6">Aucune personne actuellement présente.</td></tr>
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

                    <div class="pagination">
                        <?php for ($i = 1; $i <= $totalPersonsPages; $i++): ?>
                            <?php
                            $query = $_GET;
                            $query['persons_page'] = $i;
                            $url = '?' . http_build_query($query) . '#persons-section';
                            ?>
                            <a href="<?= esc($url) ?>" class="<?= $i === $personsPage ? 'active-page' : '' ?>">
                                <?= esc($i) ?>
                            </a>
                        <?php endfor; ?>
                    </div>
                </div>
            </div>

            <div class="card span-12" id="sessions-section">
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
                                <tr><td colspan="9">Aucune session disponible.</td></tr>
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
                                        <td><?= $row['montant'] !== null ? esc(number_format((float)$row['montant'], 2, ',', ' ')) . ' €' : '—' ?></td>
                                        <td><span class="tag <?= esc((string)$row['statut']) ?>"><?= esc($row['statut']) ?></span></td>
                                    </tr>
                                <?php endforeach; ?>
                            <?php endif; ?>
                        </tbody>
                    </table>

                    <div class="pagination">
                        <?php for ($i = 1; $i <= $totalSessionsPages; $i++): ?>
                            <?php
                            $query = $_GET;
                            $query['sessions_page'] = $i;
                            $url = '?' . http_build_query($query) . '#sessions-section';
                            ?>
                            <a href="<?= esc($url) ?>" class="<?= $i === $sessionsPage ? 'active-page' : '' ?>">
                                <?= esc($i) ?>
                            </a>
                        <?php endfor; ?>
                    </div>
                </div>
            </div>
        </section>
    </div>

    <script>
        const ctx = document.getElementById('parkingChart');

        if (ctx) {
            new Chart(ctx, {
                type: 'bar',
                data: {
                    labels: <?= json_encode($chartLabels, JSON_UNESCAPED_UNICODE) ?>,
                    datasets: [
                        {
                            label: 'Capacité',
                            data: <?= json_encode($chartCapacity) ?>
                        },
                        {
                            label: 'Occupées',
                            data: <?= json_encode($chartActive) ?>
                        },
                        {
                            label: 'Restantes',
                            data: <?= json_encode($chartFree) ?>
                        }
                    ]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: true,
                    plugins: {
                        legend: {
                            position: 'bottom'
                        }
                    },
                    scales: {
                        y: {
                            beginAtZero: true
                        }
                    }
                }
            });
        }
    </script>
</body>
</html>