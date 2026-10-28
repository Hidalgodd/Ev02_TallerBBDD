-- Ejecutar como usuario administrador (por ejemplo, SYSTEM/SYS).
-- El usuario creado se llama CRM_DEV. La contraseña se solicita al ejecutar
-- el script y no se guarda en el repositorio.

SET VERIFY OFF
ACCEPT dev_password CHAR PROMPT "Contraseña para el usuario CRM_DEV: " HIDE

CREATE USER crm_dev IDENTIFIED BY &&dev_password
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA 100M ON users;

GRANT CREATE SESSION TO crm_dev;
GRANT CREATE TABLE TO crm_dev;
GRANT CREATE VIEW TO crm_dev;
GRANT CREATE SEQUENCE TO crm_dev;
GRANT CREATE PROCEDURE TO crm_dev;
GRANT CREATE TRIGGER TO crm_dev;
GRANT CREATE TYPE TO crm_dev;
GRANT CREATE SYNONYM TO crm_dev;

UNDEFINE dev_password;
