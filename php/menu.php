<?php
    $dbconn = mysqli_connect('<omitted>');
    if (!$dbconn) {
        die("mySql connection failed: " . mysqli_connect_error());
    }
	$sql = "select distinct device_type from dashboard where current='y' order by device_type";
	$result = $dbconn->query($sql);
	while($row = $result->fetch_assoc()) {
		if ($menu == $row['device_type']) {
			echo "<a class=\"current\" href=index.php?menu=" . $row['device_type'] . ">" . $row['device_type'] . "</a> <br>";
		}else {
			echo "<a href=index.php?menu=" . $row['device_type'] . ">" . $row['device_type'] . "</a> <br>";
		}
	}
?>
