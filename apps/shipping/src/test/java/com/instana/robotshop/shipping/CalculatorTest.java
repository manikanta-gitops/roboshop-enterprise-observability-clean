package com.instana.robotshop.shipping;

import static org.junit.jupiter.api.Assertions.assertEquals;
import org.junit.jupiter.api.Test;

class CalculatorTest {
    @Test
    void sameCoordinatesHaveZeroDistance() {
        Calculator calculator = new Calculator(17.3850, 78.4867);
        assertEquals(0, calculator.getDistance(17.3850, 78.4867));
    }

    @Test
    void knownDistanceIsReasonable() {
        Calculator calculator = new Calculator(17.3850, 78.4867);
        long distance = calculator.getDistance(17.4065, 78.4772);
        assertEquals(3, distance, 1);
    }
}
